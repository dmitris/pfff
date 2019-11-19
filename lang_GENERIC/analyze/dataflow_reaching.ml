(* Iain Proctor, Yoann Padioleau, Jiao Li
 *
 * Copyright (C) 2009-2010 Facebook
 * Copyright (C) 2019 r2c
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file license.txt.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * license.txt for more details.
 *)
open Common

module F = Controlflow
module D = Dataflow
module V = Controlflow_visitor

module NodeiSet = Dataflow.NodeiSet
module VarMap = Dataflow.VarMap
module VarSet = Dataflow.VarSet

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Reaching definitions dataflow analysis.
 *
 * A definition will "reach" another program point if there is no 
 * intermediate assignment between this definition and this program point.
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

(* For a reaching definitions analysis, the dataflow result is
 * a map from each program point (as usual), to a map from each
 * variable (as usual), to a set of nodes that define this variable
 * that are visible at this program point.
 *
 * For instance on:
 *
 * 1: $a = 1;
 * 2: if(...) {
 * 3:   $a = 2;
 * 4: } else {
 * 5:   $a = 3;
 * 6: }
 * 7: echo $a;
 *
 * then at the program point (node index) 7, then for $a the nodei set
 * is {3, 5}, but not '1'.
 *)
type mapping = Dataflow.NodeiSet.t Dataflow.mapping

(*****************************************************************************)
(* Gen/Kill *)
(*****************************************************************************)

let (defs: F.flow -> NodeiSet.t Dataflow.env) = fun flow ->
  (* the long version, could use F.fold_on_expr *)
  flow#nodes#fold (fun env (ni, node) ->
    let xs = V.exprs_of_node node in
    xs |> List.fold_left (fun env e ->

      let lvals = Lrvalue.lvalues_of_expr e in
      let vars = lvals |> List.map (fun ((s,_tok), _idinfo) -> s) in
      vars |> List.fold_left (fun env var ->
        Dataflow.add_var_and_nodei_to_env var ni env
      ) env

    ) env
  ) VarMap.empty

let (gens: F.flow -> VarSet.t array) = fun flow ->
  let arr = Dataflow.new_node_array flow VarSet.empty in
  V.fold_on_node_and_expr (fun (ni, _nd) e arr ->
    let lvals = Lrvalue.lvalues_of_expr e in
    let vars = lvals |> List.map (fun ((s,_tok), _idinfo) -> s) in
    vars |> List.iter (fun var ->
      arr.(ni) <- VarSet.add var arr.(ni);
    );
    arr
  ) flow arr

let (kills:
   NodeiSet.t Dataflow.env -> F.flow -> (NodeiSet.t Dataflow.env) array) =
 fun defs flow -> 
  let arr = Dataflow.new_node_array flow (Dataflow.empty_env()) in
  V.fold_on_node_and_expr (fun (ni, _nd) e arr ->
    let lvals = Lrvalue.lvalues_of_expr e in
    let vars = lvals |> List.map (fun ((s,_tok), _idinfo) -> s) in
    vars |> List.iter (fun var ->
      let set = NodeiSet.remove ni (VarMap.find var defs) in
      arr.(ni) <- VarMap.add var set arr.(ni);
    );
    arr
  ) flow arr

(*****************************************************************************)
(* Transfer *)
(*****************************************************************************)

let union = Dataflow.union_env
let diff = Dataflow.diff_env

(*
 * This algorithm is taken from Modern Compiler Implementation in ML, Appel,
 * 1998, pp. 382.
 *
 * The transfer is setting:
 *  - in'[n]  = U_{p in pred[n]} out[p]
 *  - out'[n] = gen[n] U (in[n] - kill[n])
 *)
let (transfer:
   gen:VarSet.t array ->
   kill:(NodeiSet.t Dataflow.env) array ->
   flow:F.flow ->
   NodeiSet.t Dataflow.transfn) =
 fun ~gen ~kill ~flow ->
  (* the transfer function to update the mapping at node index ni *)
  fun mapping ni ->

  let in' = 
    (flow#predecessors ni)#fold (fun acc (ni_pred, _) ->
       union acc mapping.(ni_pred).D.out_env
     ) VarMap.empty in
  let in_minus_kill = diff in' kill.(ni) in
  let out' = Dataflow.add_vars_and_nodei_to_env gen.(ni) ni in_minus_kill in
  {D. in_env = in'; out_env = out'}

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let (fixpoint: F.flow -> mapping) = fun flow ->
  let gen = gens flow in
  let kill = kills (defs flow) flow in

  Dataflow.fixpoint
    ~eq:NodeiSet.equal
    ~init:(Dataflow.new_node_array flow (Dataflow.empty_inout ()))
    ~trans:(transfer ~gen ~kill ~flow)
    ~forward:true
    ~flow

(*****************************************************************************)
(* Dataflow pretty printing *)
(*****************************************************************************)

let string_of_ni flow ni =
  let node = flow#nodes#assoc ni in
  match node.F.i with
  | None -> "Unknown location"
  | Some(info) ->
    let info = Parse_info.token_location_of_info info in
    spf "%s:%d:%d: "
      info.Parse_info.file info.Parse_info.line info.Parse_info.column

let display flow mapping =
  let arr = Dataflow.new_node_array flow true in

  (* Set the flag to false if the node has defined anything *)
  V.fold_on_node_and_expr (fun (ni, _nd) e () ->
    let lvals = Lrvalue.lvalues_of_expr e in
    (* TODO: filter just Locals here! *)
    if lvals <> [] (* less: and ExprStmt node? why? *)
    then arr.(ni) <- false
  ) flow ();

  (* Now flag the def if it is ever used on rhs *)
  V.fold_on_node_and_expr (fun (ni, _nd) e () ->
     let rvals = Lrvalue.rvalues_of_expr e in
     (* TODO: filter just local here! *)
     let vars = rvals |> List.map (fun ((s,_tok), _idinfo) -> s) in
     vars |> List.iter (fun var ->
       let in_env = mapping.(ni).D.in_env in
       (try
         let ns = VarMap.find var in_env in
         NodeiSet.iter (fun n -> arr.(n) <- true) ns
       with Not_found -> 
         pr (spf "%s: Undefined variable %s" (string_of_ni flow ni) var)
       );
     );
  ) flow ();

  arr |> Array.iteri (fun i x ->
    if (not x)
    then pr (spf "%s: Dead Assignment" (string_of_ni flow i));
  )