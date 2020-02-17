(* Yoann Padioleau
 *
 * Copyright (C) 2020 r2c
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

open Cst_php
open Ast_php
module G = Ast_generic

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Ast_php to Ast_generic.
 *
 * See ast_generic.ml for more information.
 *)

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)
let id       = fun x -> x
let option   = Common.map_opt
let list     = List.map
let vref f x = ref (f !x)

let bool   = id
let string = id

let error = Ast_generic.error
let fake  = Ast_generic.fake
let fake_bracket = Ast_generic.fake_bracket

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let info x = x

let wrap = fun _of_a (v1, v2) ->
  let v1 = _of_a v1 and v2 = info v2 in 
  (v1, v2)

let bracket of_a (t1, x, t2) = (info t1, of_a x, info t2)

let ident v = wrap string v

let var v = wrap string v

let qualified_ident v = list ident v

let name_of_qualified_ident xs =
  match List.rev (qualified_ident xs) with
  | [] -> raise Impossible
  | [x] -> x, { G.name_qualifier = None; name_typeargs = None }
  | x::y::xs -> x, { G.name_qualifier = Some (List.rev (y::xs)); 
                       name_typeargs = None }

let name v = qualified_ident v

let rec fixOp x = x
and binaryOp (x, t) =
  match x with
  | BinaryConcat -> Right (G.Concat, t)
  | CombinedComparison -> Left (G.Cmp, t)
  | ArithOp op -> Left (op, t)

and unaryOp x = x

let modifierbis =
  function
  | Public -> G.Public
  | Private -> G.Private
  | Protected -> G.Protected
  | Static -> G.Static
  | Abstract -> G.Abstract
  | Final -> G.Final
  | Async -> G.Async

let ptype (x, t) =
  match x with
  | BoolTy -> G.TyBuiltin ("bool", t)
  | IntTy -> G.TyBuiltin ("int", t)
  | DoubleTy -> G.TyBuiltin ("double", t)
  | StringTy -> G.TyBuiltin ("string", t)
  (* TODO: TyArray of gen? *)
  | ArrayTy -> G.TyBuiltin ("array", t)
  | ObjectTy -> G.TyBuiltin ("object", t)


let list_expr_to_opt xs =
  match xs with
  | [] -> None
  | [e] -> Some e
  | x::xs -> Some (G.Seq (x::xs))

let for_var xs = 
  xs |> List.map (fun e -> G.ForInitExpr e)

let rec stmt_aux =
  function
  | Expr v1 -> let v1 = expr v1 in 
      [G.ExprStmt v1]
  | Block v1 -> let v1 = list stmt v1 in
      [G.Block v1]
  | If ((t, v1, v2, v3)) ->
      let v1 = expr v1 and v2 = stmt v2 and v3 = stmt v3 in
      [G.If (t, v1, v2, v3)]
  | Switch ((t, v1, v2)) -> let v1 = expr v1 and v2 = list case v2 in
      [G.Switch (t, Some v1, v2)]
  | While ((t, v1, v2)) -> let v1 = expr v1 and v2 = list stmt v2 in
      [G.While (t, v1, G.stmt1 v2)]
  | Do ((t, v1, v2)) -> let v1 = list stmt v1 and v2 = expr v2 in
      [G.DoWhile (t, G.stmt1 v1, v2)]
  | For ((t, v1, v2, v3, v4)) ->
      let v1 = list expr v1
      and v2 = list expr v2
      and v3 = list expr v3
      and v4 = list stmt v4
      in
      [G.For (t, G.ForClassic (
          for_var v1, 
          list_expr_to_opt v2,
          list_expr_to_opt v3),
        G.stmt1 v4)]
          
  | Foreach ((t, v1, v2, v3)) ->
      let v1 = expr v1
      and v2 = foreach_pattern v2
      and v3 = list stmt v3
      in 
      [G.For (t, G.ForEach (v2, v1), G.stmt1 v3)]
  | Return (t, v1) -> let v1 = option expr v1 in 
      [G.Return (t, v1)]
  | Break (t, v1) -> 
      [G.Break (t, opt_expr_to_label_ident v1)]
  | Continue (t, v1) -> 
      [G.Continue (t, opt_expr_to_label_ident v1)]
  | Throw (t, v1) -> let v1 = expr v1 in
      [G.Throw (t, v1)]
  | Try ((t, v1, v2, v3)) ->
      let v1 = list stmt v1
      and v2 = list catch v2
      and v3 = finally v3
      in 
      [G.Try (t, G.stmt1 v1, v2, v3)]

  | ClassDef v1 -> let (ent, def) = class_def v1 in
      [G.DefStmt (ent, G.ClassDef def)]
  | FuncDef v1 -> let (ent, def) = func_def v1 in
      [G.DefStmt (ent, G.FuncDef def)]
  | ConstantDef v1 -> let (ent, def) = constant_def v1 in
      [G.DefStmt (ent, G.VarDef def)]
  | TypeDef v1 -> let (ent, def) = type_def v1 in
      [G.DefStmt (ent, G.TypeDef def)]
  | NamespaceDef ((t, v1, (_t1, v2, t2))) ->
      let v1 = qualified_ident v1 and v2 = list stmt v2 in
      [G.DirectiveStmt (G.Package (t, v1))] @ v2 @ 
      [G.DirectiveStmt (G.PackageEnd t2)]
  | NamespaceUse ((t, v1, v2)) ->
      let v1 = qualified_ident v1 and v2 = option ident v2 in
      [G.DirectiveStmt (G.ImportAs (t, G.DottedName v1, v2))]

  | StaticVars (t, v1) ->
      v1 |> list (fun (v1, v2) ->
          let v1 = var v1 and v2 = option expr v2 in
          let attr = [G.KeywordAttr (G.Static, t)] in
          let ent = G.basic_entity v1 attr in
          let def = { G.vinit = v2; vtype = None } in
          G.DefStmt (ent, G.VarDef def)
      )

  | Global (t, v1) -> 
      v1 |> List.map (fun e ->
          match e with
          | Id [id] -> 
              let ent = G.basic_entity id [] in
              G.DefStmt (ent, G.UseOuterDecl t)
          | _ ->
              let e = expr e in
              G.OtherStmt (G.OS_GlobalComplex, [G.E e])
     )

and stmt x = 
  G.stmt1 (stmt_aux x)

and opt_expr_to_label_ident = function
 | None -> G.LNone
 | Some e -> 
      (match e with
      | Int (s, tok) when s =~ "^[0-9]+$" -> 
            G.LInt (int_of_string s, tok)
      | Id [label] -> G.LId label
      | _ -> 
            let e = expr e in
            G.LDynamic e
      )

and case =
  function
  | Case ((t, v1, v2)) -> let v1 = expr v1 and v2 = list stmt v2 in
      [G.Case (t, G.expr_to_pattern v1)], G.stmt1 v2
  | Default (t, v1) -> let v1 = list stmt v1 in
      [G.Default t], G.stmt1 v1

and catch (v1, v2, v3) =
  let v1 = hint_type v1 and v2 = var v2 and v3 = list stmt v3 in
  let pat = G.PatVar (v1, Some (v2, G.empty_id_info())) in
  pat, G.stmt1 v3

and finally (v: finally list) = 
  let xs = list (list stmt) v in
  let xs = List.flatten xs in
  match xs with
  | [] -> None
  | xs -> Some (G.stmt1 xs)

and expr =
  function
  | Int v1 -> let v1 = wrap id v1 in 
      G.L (G.Int v1)
  | Double v1 -> let v1 = wrap id v1 in 
      G.L (G.Float v1)
  | String v1 -> let v1 = wrap string v1 in 
      G.L (G.String v1)
  | Id v1 -> let v1 = name_of_qualified_ident v1 in 
      G.Name (v1, G.empty_id_info ())
  | IdSpecial v1 ->
      let v1 = wrap special v1 in
      G.IdSpecial (v1)
  (* unify Id and Var, finally *)      
  | Var v1 -> let v1 = var v1 in 
      G.Name ((v1, G.empty_name_info), G.empty_id_info())
  | Array_get ((v1, Some v2)) ->
      let v1 = expr v1 and v2 = expr v2 in 
      G.ArrayAccess (v1, v2)
  | Array_get ((v1, None)) ->
      let v1 = expr v1 in
      raise Todo
  | Obj_get ((v1, t, Id [v2])) -> 
      let v1 = expr v1 and v2 = ident v2 in
      G.DotAccess (v1, t, G.FId v2)
  | Obj_get ((v1, t, v2)) -> 
      let v1 = expr v1 and v2 = expr v2 in
      G.DotAccess (v1, t, G.FDynamic v2)
  | Class_get ((v1, t, Id [v2])) -> let v1 = expr v1 and v2 = ident v2 in
      G.DotAccess (v1, t, G.FId v2)
  | Class_get ((v1, t, v2)) -> let v1 = expr v1 and v2 = expr v2 in
      G.DotAccess (v1, t, G.FDynamic v2)
  | New ((t, v1, v2)) -> let v1 = expr v1 and v2 = list expr v2 in 
      G.Call (G.IdSpecial(New, t), (v1::v2) |> List.map G.expr_to_arg)
  | InstanceOf ((t, v1, v2)) -> let v1 = expr v1 and v2 = expr v2 in
      G.Call (G.IdSpecial(Instanceof, t), ([v1;v2]) |> List.map G.expr_to_arg)
  | Assign ((v1, t, v3)) ->
      let v1 = expr v1
      and v3 = expr v3
      in 
      G.Assign (v1, t, v3)
  | AssignOp ((v1, v2, v3)) ->
      let v2 = binaryOp v2
      and v1 = expr v1
      and v3 = expr v3
      in 
      (match v2 with
      | Left (op, t) -> G.AssignOp (v1, (op, t), v3)
      | Right (special, t) -> 
        (* todo: should introduce intermediate var *)
        G.Assign (v1, t, 
                  G.Call (G.IdSpecial (special, t), [G.Arg v1; G.Arg v3]))
      )
  | List v1 -> let v1 = bracket (list expr) v1 in
      G.Container(G.List, v1)
  | Arrow ((v1, _t, v2)) -> let v1 = expr v1 and v2 = expr v2 in
      G.Tuple [v1; v2]
  | Ref (t, v1) -> let v1 = expr v1 in
      G.Ref (t, v1)
  | Unpack v1 -> let v1 = expr v1 in
      G.OtherExpr(G.OE_Unpack, [G.E v1])
  | Call ((v1, v2)) -> let v1 = expr v1 and v2 = list expr v2 in 
      G.Call (v1, v2 |> List.map G.expr_to_arg)
  | Infix (((v1, t), v2)) -> 
      let v1 = fixOp v1 and v2 = expr v2 in 
      G.Call (G.IdSpecial (G.IncrDecr (v1, G.Prefix), t), [G.Arg v2])
  | Postfix (((v1, t), v2)) ->
      let v1 = fixOp v1 and v2 = expr v2 in 
      G.Call (G.IdSpecial (G.IncrDecr (v1, G.Postfix), t), [G.Arg v2])
  | Binop ((v1, v2, v3)) ->
      let v2 = binaryOp v2
      and v1 = expr v1
      and v3 = expr v3
      in
      (match v2 with
      | Left (op, t) -> 
         G.Call (G.IdSpecial (G.ArithOp op, t), [G.Arg v1; G.Arg v3])
      | Right x -> 
         G.Call (G.IdSpecial (x), [G.Arg v1; G.Arg v3])
      )
  | Unop (((v1, t), v2)) -> let v1 = unaryOp v1 and v2 = expr v2 in 
      G.Call (G.IdSpecial (G.ArithOp v1, t), [G.Arg v2])
  | Guil (t, v1, _) -> let v1 = list expr v1 in
      G.Call (G.IdSpecial (G.Concat, t), v1 |> List.map G.expr_to_arg)
  | ConsArray v1 -> let v1 = bracket (list array_value) v1 in
      G.Container (G.Array, v1)
  | Collection ((v1, v2)) ->
      let v1 = name_of_qualified_ident v1 
      and v2 = bracket (list array_value) v2 in 
      G.Call (G.IdSpecial (G.New, fake "new"),
        [G.Arg (G.Name (v1, G.empty_id_info()));
         G.Arg (G.Container (G.Dict, v2))])
  | Xhp v1 -> let v1 = xml v1 in 
      G.Xml v1
  | CondExpr ((v1, v2, v3)) ->
      let v1 = expr v1 and v2 = expr v2 and v3 = expr v3 in
      G.Conditional (v1, v2, v3)
  | Cast ((v1, v2)) -> let v1 = ptype v1 and v2 = expr v2 in
      G.Cast(v1, v2)
  | Lambda v1 -> 
      let tok = snd v1.f_name in
      (match v1 with
      | { f_kind = AnonLambda; f_ref = false; m_modifiers = [];
          l_uses = []; f_attrs = [];
          f_params = ps; f_return_type = rett;
          f_body = body } ->
            let body = G.stmt1 (list stmt body) in
            let ps = parameters ps in
            let rett = option hint_type rett in
            (* TODO: transform l_uses in UseOuterDecl preceding body *)
            G.Lambda { G.fparams = ps; frettype = rett; fbody = body }
      | _ -> error tok "TODO: Lambda"
      )

and special = function
  | This -> G.This
  | Eval -> G.Eval

and xhp =
  function
  | XhpText v1 -> let v1 = string v1 in G.XmlText v1
  | XhpExpr v1 -> let v1 = expr v1 in G.XmlExpr v1
  | XhpXml v1 -> let v1 = xml v1 in G.XmlXml v1

and xml { xml_tag = xml_tag; xml_attrs = xml_attrs; xml_body = xml_body } =
  let tag = ident xml_tag in
  let attrs =
    list (fun (v1, v2) -> let v1 = ident v1 and v2 = xhp_attr v2 in v1, v2)
    xml_attrs in
  let body = list xhp xml_body in 
  { G.xml_tag = tag; xml_attrs = attrs; xml_body = body }

and xhp_attr v          = expr v

and foreach_pattern v   = 
  let v = expr v in
  G.expr_to_pattern v

and array_value v       = expr v
and string_const_expr v = expr v

and hint_type =
  function
  | Hint v1 -> let v1 = name v1 in 
      G.TyName (name_of_qualified_ident v1)
  | HintArray t -> 
      G.TyBuiltin ("array", t)
  | HintQuestion (t, v1) -> let v1 = hint_type v1 in 
      G.TyQuestion (v1, t)
  | HintTuple (t1, v1, t2) -> let v1 = list hint_type v1 in
      G.TyTuple (t1, v1, t2)
  | HintCallback ((v1, v2)) ->
      let v1 = list hint_type v1 and v2 = option hint_type v2 in 
      let params = v1 |> List.map G.param_of_type in
      let fret = 
        match v2 with
        | Some t -> t
        | None -> G.TyBuiltin ("void", fake "void")
      in
      G.TyFun (params, fret)
  | HintShape (tok, (t1, v1, t2)) ->
      let v1 =
        list
          (fun (v1, v2) ->
             let v1 = string_const_expr v1 and v2 = hint_type v2 in
             match v1 with
             | G.L (G.String (s, t)) -> (s,t), v2
             | _ -> error tok "HintShape with non-string keys not supported"
          )
          v1
      in 
      G.TyAnd (t1, v1, t2)

  | HintTypeConst (_, tok,_) -> 
    error tok "HintTypeConst not supported, facebook-ext"
  | HintVariadic (tok, _) -> 
    error tok "HintVariadic not supported"

and class_name v = hint_type v

and func_def {
               f_name = f_name;
               f_kind = f_kind;
               f_params = f_params;
               f_return_type = f_return_type;
               f_ref = f_ref;
               m_modifiers = m_modifiers;
               l_uses = l_uses;
               f_attrs = f_attrs;
               f_body = f_body
             } =
  let id = ident f_name in
  let _fkind = function_kind f_kind in
  let params = parameters f_params in
  let fret = option hint_type f_return_type in
  let _is_refTODO = bool f_ref in
  let modifiers = list modifier m_modifiers 
    |> List.map (fun m -> G.KeywordAttr m) in
  (* todo: transform in UseOuterDecl before first body stmt *)
  let _lusesTODO =
    list (fun (v1, v2) -> let v1 = bool v1 and v2 = var v2 in ())
      l_uses in
  let attrs = list attribute f_attrs in
  let body = list stmt f_body |> G.stmt1 in 
  let ent = G.basic_entity id (modifiers @ attrs) in
  let def = { G.fparams = params; frettype = fret; fbody = body } in
  ent, def

and function_kind =
  function
  | Function -> ()
  | AnonLambda -> ()
  | ShortLambda -> ()
  | Method -> ()

and parameters x = list parameter x

and parameter {
                p_type = p_type;
                p_ref = p_ref;
                p_name = p_name;
                p_default = p_default;
                p_attrs = p_attrs;
                p_variadic = p_variadic;
              } =
  let p_type = option hint_type p_type in
  let p_name = var p_name in
  let p_default = option expr p_default in
  let p_attrs = list attribute p_attrs in
  let attrs = p_attrs @ 
    (match p_variadic with 
    | None -> [] 
    | Some tok -> [G.KeywordAttr (G.Variadic, tok)]
    ) in
  let pclassic = G.ParamClassic
  { G.pname = Some p_name; ptype = p_type; pdefault = p_default;
    pattrs = attrs; pinfo = G.empty_id_info() } in
  (match p_ref with
  | None -> pclassic
  | Some tok -> G.OtherParam (G.OPO_Ref, [G.Pa pclassic])
  )

and modifier v = wrap modifierbis v

and attribute v = 
  match v with
  | Id [id] -> 
    let id = ident id in
    G.NamedAttr (id, [])
  | Call (Id [id], args) ->
    let id = ident id in
    let args = list expr args in
    G.NamedAttr (id, args |> List.map G.expr_to_arg)
  | _ -> raise Impossible (* see ast_php_build.ml *)
                 

and constant_def { cst_name = cst_name; cst_body = cst_body; cst_tok = tok } =
  let id = ident cst_name in let body = option expr cst_body in
  let attr = [G.KeywordAttr (G.Const, tok)] in
  let ent = G.basic_entity id attr in
  ent, { G.vinit = body; vtype = None }

and enum_type tok { e_base = e_base; e_constraint = e_constraint } =
  let arg = hint_type e_base in
  let arg = option hint_type e_constraint in
  error tok "enum type not supported"

and class_def {
                c_name = c_name;
                c_kind = c_kind;
                c_extends = c_extends;
                c_implements = c_implements;
                c_uses = c_uses;
                c_enum_type = c_enum_type;
                c_attrs = c_attrs;
                c_xhp_fields = c_xhp_fields;
                c_xhp_attr_inherit = c_xhp_attr_inherit;
                c_constants = c_constants;
                c_variables = c_variables;
                c_methods = c_methods
              } =
  let tok = snd c_name in

  let id = ident c_name in
  let kind = class_kind c_kind in
  let extends    = option class_name c_extends in
  let implements = list class_name c_implements in
  let uses       = list class_name c_uses in

  let _enum = option (enum_type tok) c_enum_type in
  let _xhp1 = list xhp_field c_xhp_fields in
  let _xhp2 = list class_name c_xhp_attr_inherit in

  let attrs = list attribute c_attrs in

  let csts = list constant_def c_constants in
  let vars = list class_var c_variables in
  let methods  = list method_def c_methods in 
  raise Todo

and class_kind =
  function
  | ClassRegular -> ()
  | ClassFinal -> ()
  | ClassAbstract -> ()
  | ClassAbstractFinal -> ()
  | Interface -> ()
  | Trait -> ()
  | Enum -> ()

and xhp_field (v1, v2) = let v1 = class_var v1 and v2 = bool v2 in ()

and class_var {
                cv_name = cname;
                cv_type = ctype;
                cv_value = cvalue;
                cv_modifiers = cmodifiers
              } =
  let arg = var cname in
  let arg = option hint_type ctype in
  let arg = option expr cvalue in
  let arg = list modifier cmodifiers in ()

and method_def v = func_def v

and type_def { t_name = t_name; t_kind = t_kind } =
  let id = ident t_name in let kind = type_def_kind (snd t_name) t_kind in
  let ent = G.basic_entity id [] in
  ent, { G.tbody = kind }

and type_def_kind tok =
  function
  | Alias v1 -> let v1 = hint_type v1 in
      G.AliasType v1
  | Newtype v1 -> let v1 = hint_type v1 in
      G.NewType v1
  | ClassConstType _v1 -> 
    error tok "ClassConstType not supported, facebook-ext"
      

and program v = 
  list stmt v

let any =
  function
  | Program v1 -> let v1 = program v1   in G.Pr v1
  | Stmt v1    -> let v1 = stmt v1      in G.S v1
  | Expr2 v1   -> let v1 = expr v1      in G.E v1
  | Param v1   -> let v1 = parameter v1 in G.Pa v1

