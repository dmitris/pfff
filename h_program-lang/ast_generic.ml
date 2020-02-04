(* Yoann Padioleau
 *
 * Copyright (C) 2019-2020 r2c
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

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* A generic AST, to factorize similar analysis in different programming
 * languages (e.g., scheck, sgrep). 
 *
 * Right now this generic AST is mostly the factorized union of:
 *  - Python
 *  - Javascript
 *  - Java
 *  - C
 *  - Go
 *  - TOFINISH OCaml
 *  - TODO PHP
 *
 * rational: In the end, programming languages have a lot in common.
 * Even though most interesting analysis are probably better done on a
 * per-language basis, many useful analysis are trivial and require just an
 * AST and a visitor. One could duplicate those analysis for each language
 * or design an AST (this file) generic enough to factorize all those 
 * analysis (e.g., unused entity). We want to remain
 * as precise as possible and not lose too much information while going
 * from the specific language AST to the generic AST. We also do not want
 * to be too generic as in ast_fuzzy.ml, where we have a very general 
 * tree of nodes, but all the structure of the original AST is lost.
 * 
 * TODO:
 *  - later: add Ruby, Rust, Scala (difficult)
 *  - later: add C++ (argh)
 *  - see ast_fuzzy.ml TODOs for ideas to use ast_generic for sgrep.
 *
 * related work:
 *  - ast_fuzzy.ml (in this directory)
 *  - github semantic
 *    https://github.com/github/semantic
 *  - UAST of babelfish
 *    https://doc.bblf.sh/uast/uast-specification-v2.html
 *  - Coverity common program representation?
 *  - Semmle internal common representation?
 *  - Infer SIL (for C++, Java, Objective-C)
 *  - Dawson Engler and Fraser Brown micro-checkers for multiple languages
 *  - Lightweight Multi-language syntax transformation paper, but does not
 *    really operate on an AST
 *  - https://tabnine.com/ which supports multiple languages, but probably
 *    again does not operate on an AST
 *  - srcML https://www.srcml.org/doc/srcMLGrammar.html
 *    but just for C/C++/C#/Java and seems pretty heavy
 *
 * design choices to have a generic data structure:
 *  - add some 'a, 'b, 'c around expr/stmt/...
 *  - data-type a la carte like in github-semantic but IMHO too high-level
 *    with astronaut-style architecture (too abstract, too advanced features).
 *  - the OtherXxx strategy used in this file (simple)
 *  - functorize and add some type hole (type tstmt; type texpr; ...),
 *    todo? not a bad idea if later we want to add type information on each
 *    expression nodes
 *
 * history:
 *  - started with crossproduct of Javascript, Python, PHP, Java, and C
 *    (and a bit of OCaml) after wanting to port checked_return from Js to
 *    Python and got the idea to factorize things
 *
 * INVARIANTS:
 *  - all the other_xxx types should contain only simple constructors (enums)
 *    without any parameter. I rely on that to simplify the code 
 *    of the generic mapper and matcher.
 *    Same for keyword_attribute.
 *  - each expression or statement must have at least one token in it
 *    so that sgrep can report correctly ranges (e.g., 'Return of expr option'
 *    is not enough because with no expr, there is no location information
 *    for this return, so it must be 'Return of tok * expr option' instead)
 *  - to correctly compute a CFG (Control Flow Graph), the stmt type 
 *    should list all constructs that contains other statements and 
 *    try to avoid to use the very generic OtherXxx of any
 *  - to correctly compute a DFG (Data Flow Graph), each constructs that
 *    introduce a new variable should have a relevant comment 'newvar:'
 *  - to correctly resolve names, each constructs that introduce a new scope
 *    should have a relevant comment 'newscope:'
 *  - TODO each language should add the VarDefs that defines the locals
 *    used in a function (instead of having the first Assign play the role
 *    of a VarDef, as done in Python for example).
 *
 * See also pfff/lang_GENERIC/
 *)

(*****************************************************************************)
(* Token (leaf) *)
(*****************************************************************************)

(* Contains among other things the position of the token through
 * the Parse_info.token_location embedded inside it, as well as the
 * transformation field that makes possible spatch on the code.
 *)
type tok = Parse_info.t
 (* with tarzan *)

(* a shortcut to annotate some information with position information *)
type 'a wrap = 'a * tok
 (* with tarzan *)

(* Use for round(), square[], curly{}, and angle<> brackets. 
 * note: in theory we should not care about those tokens in an AST, 
 * but they are useful to report correct ranges in sgrep when we match
 * something that can just be those brackets (e.g., an empty container).
 *)
type 'a bracket = tok * 'a * tok
 (* with tarzan *)

(*****************************************************************************)
(* Names *)
(*****************************************************************************)

type ident = string wrap
 (* with tarzan *)

type dotted_ident = ident list (* at least 1 element *)
 (* with tarzan *)

(* module_name can also be used for a package name or a namespace *)
type module_name =
  | DottedName of dotted_ident (* ex: Python *)
  (* in that case the '.' is really the '/' *)
  | FileName of string wrap   (* ex: Js import, C #include, Go import *)
 (* with tarzan *)

(* see also scope_code.ml *)
type resolved_name =
  | Local of gensym
  | Param of gensym (* could merge with Local *)
  (* for closures; can refer to a Local or Param *)
  | EnclosedVar of gensym (* TODO? and depth? *)

  (* both dotted_ident must at least contain one element *)
  | Global of dotted_ident (* or just name? *) (* can also use 0 for gensym *)
  | ImportedModule of module_name
  | TypeName (* in Go, where you can pass types as arguments *)
  | Macro
  | EnumConstant

  (* this simplifies further analysis which need less to care about 
   * maintaining scoping information to deal with variable shadowing, 
   * functions using the same parameter names, etc.
   *)
  and gensym = int (* a unique gensym'ed number *)
 (* with tarzan *)

(* big mutually recursive types because of the use of 'any' in OtherXxx *)

type name = ident * name_info
  and name_info = { 
    name_qualifier: qualifier option;
    name_typeargs: type_arguments option; (* Java *)
  } 
  (* todo: not enough in OCaml with functor and type args or C++ templates*)
  and qualifier = dotted_ident

(*****************************************************************************)
(* Naming/typing *)
(*****************************************************************************)

and id_info = {
    id_resolved: resolved_name option ref; (* variable tagger (naming) *)
    id_type:     type_         option ref; (* type checker (typing) *)
  }

(*****************************************************************************)
(* Expression *)
(*****************************************************************************)

and expr = 
  (* basic (atomic) values *)
  | L of literal

  (* composite values *)
  | Container of container_operator * expr list bracket
  | Tuple of expr list (* special case of Container, at least 2 elements *) 

  (* And-type (field.vinit should be a Some) *)
  | Record of field list bracket
  (* Or-type (could be used instead of Container, Cons, Nil, etc.) *)
  | Constructor of name * expr list
  (* see also Call(IdSpecial (New,_), [ArgType _;...] for other values *)

  (* very special value *)
  | Lambda of function_definition
  (* usually an argument of a New (used in Java, Javascript) *)
  | AnonClass of class_definition

  | Nop (* less: could be merged with L Unit, TODO: remove? *)

  (* todo: newvar: sometimes abused to also introduce a newvar (as in Python)
   * but ultimately those cases should be rewritten to first introduce a
   * VarDef. 
   * todo: Sometimes some ObjAccess should really be transformed in Name
   * with a better qualifier because the obj is actually the name of a package
   * or module, but you may need advanced semantic information and global
   * analysis to disambiguate.
   *)
  | Name of name * id_info
  | IdSpecial of special wrap

  (* operators and function application *)
  | Call of expr * arguments
  (* (XHP, JSX, TSX), could transpile also *)
  | Xml of xml
  (* IntepolatedString of expr list is simulated with a 
   * Call(IdSpecial (Concat ...)) *)

  (* The left part should be an lvalue (id, ObjAccess, ArrayAccess, Deref)
   * but it can also be a pattern (Tuple, Container), but
   * you should really use LetPattern for that.
   * Assign can also be abused to declare new variables, but you should use
   * variable_definition for that.
   * less: should be in stmt, but most languages allow this at expr level :(
   * update: should even be in a separate simple_stmt, as in Go
   *)
  | Assign of expr * tok (* =, or sometimes := in Go, <- in ML *) * expr
  (* less: should desugar in Assign, should be only binary_operator *)
  | AssignOp of expr * arithmetic_operator wrap * expr
  (* newvar:! newscope:? in OCaml yes but we miss the 'in' part here  *)
  | LetPattern of pattern * expr

  (* can be used for Record, Class, or Module access depending on expr.
   * In the last case it should be rewritten as a Name with a qualifier though.
   *)
  | DotAccess of expr * tok (* ., ::, ->, # *) * ident
  (* in Js this is used for ObjAccess with a computed field name *)
  | ArrayAccess of expr * expr
  (* could also use ArrayAccess with a Tuple rhs, or use a special *)
  | SliceAccess of expr * 
      expr option (* lower *) * expr option (* upper *) * expr option (* step*)

  (* a.k.a ternary expression, or regular if in ML *)
  | Conditional of expr * expr * expr 
  | MatchPattern of expr * action list
  (* less: TryFunctional *)

  | Yield of tok * expr option * bool (* 'from' for Python *)
  | Await of tok * expr
  (* Send/Recv of Go are currently in OtherExpr *)

  | Cast of type_ * expr
  (* less: should be in statement *)
  | Seq of expr list (* at least 2 elements *)

  (* less: could be in Special *)
  | Ref   of tok (* &, address of *) * expr 
  | DeRef of tok (* '*' in C, '!' or '<-' in ML *) * expr 

  | Ellipsis of tok (* sgrep: ... in args, stmts, and also types in Python *)

  | OtherExpr of other_expr_operator * any list

  and literal = 
    | Bool of bool wrap
    | Int of string wrap | Float of string wrap
    | Char of string wrap | String of string wrap | Regexp of string wrap
    | Unit of tok (* a.k.a Void *) | Null of tok | Undefined of tok (* JS *)
    | Imag of string wrap (* Go, Python *)

  and container_operator = 
    (* Tuple was lifted up *)
    | Array (* todo? designator? use ArrayAccess for designator? *)
    | List | Set
    | Dict (* a.k.a Hash or Map (combine with Tuple to get Key/value pair) *)


  and special = 
   (* special vars *)
   | This | Super
   | Self | Parent (* different from This/Super? *)

   (* special apply *)
   | Eval
   | Typeof (* for C? and Go in switch x.(type) *)
   | Instanceof | Sizeof
   (* note that certain languages do not have a 'new' keyword (e.g., Python),
    * instead certain 'Call' are really 'New' *)
   | New  (* usually associated with Call(New, [ArgType _;...]) *)

   | Concat (* used for interpolated strings constructs *)
   | Spread (* inline list var, in Container or call context *)

   | ArithOp of arithmetic_operator
   (* should be lift up and transformed in Assign at stmt level *)
   | IncrDecr of (incr_decr * prefix_postfix)

    (* mostly binary operator 
     * less: could be divided in really Arith vs Logical (bool) operators,
     * but see is_boolean_operator() helper below.
     * Note that Mod can be used for %style string formatting in Python.
     * todo? use a Special operator intead for that? but need type info?
     * Plus can be used for string concatenations in Go.
     *)
    and arithmetic_operator = 
      | Plus (* unary too *) | Minus (* unary too *) 
      | Mult | Div | Mod
      | Pow | FloorDiv | MatMult (* Python *)
      | LSL | LSR | ASR (* L = logic, A = Arithmetic, SL = shift left *) 
      | BitOr | BitXor | BitAnd | BitNot (* unary *) | BitClear (* Go *)
      (* todo? rewrite in CondExpr? have special behavior *)
      | And | Or (* also shortcut operator *) | Xor (* PHP*) | Not (* unary *)
      | Eq     | NotEq     (* less: could be desugared to Not Eq *)
      | PhysEq | NotPhysEq (* less: could be desugared to Not PhysEq *)
      | Lt | LtE | Gt | GtE  (* less: could be desugared to Or (Eq Lt) *)
    and incr_decr = Incr | Decr
    and prefix_postfix = Prefix | Postfix

  (* newscope: newvar: *)
  and action = pattern * expr

  (* TODO *)
  and xml = any list

  and arguments = argument list
    and argument =
      (* regular argument *)
      | Arg of expr (* can be Call (IdSpecial Spread, Id foo) *)
      (* keyword argument *)
      | ArgKwd of ident * expr
      (* type argument for New, instanceof/sizeof/typeof, C macros *)
      | ArgType of type_

      | ArgOther of other_argument_operator * any list

       and other_argument_operator =
        (* Python *)
        | OA_ArgPow (* a kind of Spread, but for Dict instead of List *)
        | OA_ArgComp (* comprehension *)
        (* OCaml *)
        | OA_ArgQuestion

  (* TODO: reduce *)
  and other_expr_operator = 
    (* Javascript *)
    | OE_Exports | OE_Module 
    | OE_Define | OE_Arguments 
    | OE_NewTarget
    | OE_Delete | OE_YieldStar
    | OE_Encaps (* less: convert to regular funcall? *)
    | OE_Require (* todo: lift to Import? *) 
    | OE_UseStrict (* less: lift up to program attribute/directive? *)
    | OE_ObjAccess_PN_Computed (* less: convert to ArrayAccess *)
    (* Python *)
    | OE_Is | OE_IsNot (* less: could be part of a set_operator? or PhysEq? *)
    | OE_In | OE_NotIn (* less: could be part of a obj_operator? *)
    | OE_Invert
    | OE_Slices | OE_SliceIndex | OE_SliceRange (* see also SliceAccess *)
    (* TODO: newvar: *)
    | OE_CompForIf | OE_CompFor | OE_CompIf
    | OE_CmpOps
    | OE_Repr (* lift up? special Dump? *)
    (* Java *)
    | OE_NameOrClassType | OE_ClassLiteral | OE_NewQualifiedClass
    (* C *)
    | OE_GetRefLabel
    | OE_ArrayInitDesignator (* [x] = ... todo? use ArrayAccess in container?*)
    (* PHP *)
    | OE_Unpack
    (* OCaml *)
    | OE_FieldAccessQualified | OE_RecordWith 
    | OE_StmtExpr (* OCaml has just expressions, no statements *)
    (* Go *)
    | OE_Send | OE_Recv

(*****************************************************************************)
(* Statement *)
(*****************************************************************************)
and stmt =
  (* later: lift Call/Assign/Seq here *)
  | ExprStmt of expr

  | DefStmt of definition
  | DirectiveStmt of directive

  (* newscope: in C++/Java/Go *)
  | Block of stmt list (* TODO: bracket *)
  (* EmptyStmt = Block [], or separate so can not be matched by $S? *)

  | If of tok (* 'if' or 'elif' *) * expr * stmt * stmt
  | While of tok * expr * stmt
  | DoWhile of tok * stmt * expr
  (* newscope: *)
  | For of tok * for_header * stmt

  (* less: could be merged with ExprStmt (MatchPattern ...) *)
  | Switch of tok (* switch or also Select in Go *) * expr * case_and_body list

  | Return   of tok * expr option
  (* less: switch to label? but PHP accept integers no? *)
  | Continue of tok * expr option 
  | Break    of tok * expr option 

  | Label of label * stmt
  | Goto of tok * label

  | Throw of tok * expr (* a.k.a raise *)
  | Try of tok * stmt * catch list * finally option
  | Assert of tok * expr * expr option (* message *)

  (* this is important to correctly compute a CFG *)
  | OtherStmtWithStmt of other_stmt_with_stmt_operator * expr * stmt
  (* any here should not contain any statement! otherwise the CFG will be
   * incorrect and some analysis (e.g., liveness) will be incorrect.
   *)
  | OtherStmt of other_stmt_operator * any list

  (* newscope: *)
  (* less: could merge even more with pattern
   * list = PatDisj and Default = PatUnderscore, 
   * so case_and_body of Switch <=> action of MatchPattern
   *)
  and case_and_body = case list * stmt
    and case  =
    | Case    of tok * pattern
    | Default of tok

  (* newvar: newscope: *)
  and catch = pattern * stmt
  (* newscope: *)
  and finally = stmt

  and label = ident

  and for_header = 
    (* todo? copy Go and have instead   
     * ForClassic of simple option * expr * simple option?
     *)
    | ForClassic of for_var_or_expr list (* init *) * 
                    expr (* cond *) * 
                    expr (* next *)
    (* newvar: *)
    | ForEach of pattern * expr (* pattern 'in' expr *)

    and for_var_or_expr = 
    (* newvar: *)
    | ForInitVar of entity * variable_definition
    | ForInitExpr of expr

  and other_stmt_with_stmt_operator = 
    (* Python *)
    | OSWS_With (* TODO: newvar: in OtherStmtWithStmt with LetPattern 
                 * and newscope: *)

  and other_stmt_operator = 
    (* Python *)
    | OS_Delete 
    (* TODO: reduce? transpile? *)
    | OS_ForOrElse | OS_WhileOrElse | OS_TryOrElse
    | OS_ThrowFrom | OS_ThrowNothing | OS_Global | OS_NonLocal
    | OS_Pass
    | OS_Async
    (* Java *)
    | OS_Sync
    (* C *)
    | OS_Asm
    (* Go *)
    | OS_Go | OS_Defer 
    | OS_Fallthrough

(*****************************************************************************)
(* Pattern *)
(*****************************************************************************)
and pattern = 
  | PatLiteral of literal
  (* Or-Type *)
  | PatConstructor of name * pattern list
  (* And-Type *)
  | PatRecord of field_pattern list (* TODO: bracket *)

  (* newvar:! *)
  | PatVar of ident * id_info (* Always Local or Param *)

  (* special cases of PatConstructor *)
  | PatTuple of pattern list
  | PatList of pattern list (* TODO bracket *)
  | PatKeyVal of pattern * pattern (* a kind of PatTuple *)

  (* special case of PatVar *)
  | PatUnderscore of tok

  (* OCaml *)
  | PatDisj  of pattern * pattern
  | PatTyped of pattern * type_
  | PatWhen  of pattern * expr
  | PatAs    of pattern * (ident * id_info)

  (* Go *)
  | PatType of type_

  | OtherPat of other_pattern_operator * any list

  and field_pattern = name * pattern

  and other_pattern_operator =
  (* Python *)
  | OP_ExprPattern (* todo: should transform in pattern when can *)
  (* Javascript *)
  | OP_Var (* todo: should transform in pattern when can *)

(*****************************************************************************)
(* Type *)
(*****************************************************************************)

and type_ =
  (* todo? a type_builtin = TInt | TBool | ...? see Literal *)
  | TyBuiltin of string wrap (* int, bool, etc. could be TApply with no args *)
  (* old: was type_, but languages such as C and Go allow also to name
   * those parameters, and Go even allow Variadic params so we need
   * at least type_ * attributes, at which point it's better to just use 
   * parameter_classic
   *)
  | TyFun of parameter_classic list * type_ (* return type *)
  (* covers tuples, list, etc. and also regular typedefs *)
  | TyApply of name * type_arguments
  | TyVar of ident (* typedef? no type variable in polymorphic type *)

  (* a special case of TApply, also a special case of TPointer *)
  | TyArray of (* const_expr *) expr option * type_
  | TyPointer of tok * type_
  | TyTuple of type_ list
  | TyQuestion of type_ (* option type *)

  | OtherType of other_type_operator * any list
  
  and type_arguments = type_argument list

    and type_argument = 
      | TypeArg of type_

      | OtherTypeArg of other_type_argument_operator * any list

      and other_type_argument_operator =
       | OTA_Question

  and other_type_operator = 
  (* Python *)
  | OT_Expr | OT_Arg (* todo: should transform in type_ when can *)
  (* C *)
  (* TODO? convert in unique name with TyApply ?*)
  | OT_StructName | OT_UnionName | OT_EnumName 
  (* PHP *)
  | OT_Shape (* hack-specific? *) | OT_Variadic (* ???? *)

(*****************************************************************************)
(* Attribute *)
(*****************************************************************************)
(* a.k.a decorators, annotations *)
and attribute = 
  | KeywordAttr of keyword_attribute wrap
  (* for general @annotations *)
  | NamedAttr of ident * argument list

  | OtherAttribute of other_attribute_operator * any list

  and keyword_attribute =
  | Static | Volatile | Extern
  (* for class fields *)
  | Public | Private | Protected
  | Abstract | Final
  (* for vars (JS) *)
  | Var | Let
  (* for fields *)
  | Mutable | Const
  (* for functions *)
  | Generator | Async 
  | Recursive | MutuallyRecursive
  (* for methods *)
  | Ctor | Dtor
  | Getter | Setter
  (* for parameters *)
  | Variadic

  and other_attribute_operator = 
    (* Java *)
    | OA_StrictFP | OA_Transient | OA_Synchronized | OA_Native
    | OA_AnnotJavaOther
    | OA_AnnotThrow
    (* Python *)
    | OA_Expr (* todo: should transform in NamedAttr when can *)

(*****************************************************************************)
(* Definitions *)
(*****************************************************************************)
and definition = entity * definition_kind (* (or decl) *)

  and entity = {
    name: ident;
    attrs: attribute list;
    tparams: type_parameter list;
    (* naming/typing *)
    info: id_info;
    (* old: type_: type_ option; but redundant with the type information in
     * the different definition_kind, as well as in id_info, 
     * so not worth factoring.
     *)
  }

  (* can have empty "body" when the definition is actually a declaration
   * in a header file *)
  and definition_kind =
    | FuncDef   of function_definition (* valid for methods too *)
    (* newvar: *)
    | VarDef    of variable_definition (* valid for constants and fields too *)

    | TypeDef   of type_definition
    | ClassDef  of class_definition

    | ModuleDef of module_definition
    | MacroDef of macro_definition
    | Signature of type_

(* template/generics/polymorphic *)
and type_parameter = ident * type_parameter_constraints

  and type_parameter_constraints = type_parameter_constraint list

   and type_parameter_constraint = 
     | Extends of type_
 
(* ------------------------------------------------------------------------- *)
(* Function (or method) definition *)
(* ------------------------------------------------------------------------- *)
(* less: could be merged with variable_definition *)
and function_definition = {
 (* less: could be merged in entity.type_ *)
 fparams: parameters;
 frettype: type_ option; (* return type *)
 (* newscope:
  * note: can be empty statement for methods in interfaces *)
 fbody: stmt;
}
  and parameters = parameter list
    (* newvar: *)
    and parameter =
     | ParamClassic of parameter_classic
     | ParamPattern of pattern
     (* sgrep: ... in parameters
      * note: foo(...x) of Js/Go is using the Variadic attribute, not this *)
     | ParamEllipsis of tok

     | OtherParam of other_parameter_operator * any list

    (* less: could be merged with variable_definition, or pattern
     * less: could factorize pname/pattrs/pinfo with entity
     *)
    and parameter_classic = { 
     (* alt: use a 'ParamNoIdent of type_' when pname is None instead? *)
     pname:    ident option;
     ptype:    type_ option;
     pdefault: expr  option;
     (* this covers '...' variadic parameters, see the Variadic attribute *)
     pattrs: attribute list;
     (* naming *)
     pinfo: id_info; (* Always Param *)
    }
  and other_parameter_operator =
     (* Python *)
     | OPO_KwdParam | OPO_SingleStarParam
     (* PHP *)
     | OPO_Ref (* less: or encode in type? *)
     (* Go *)
     | OPO_Receiver (* of parameter_classic *)

(* ------------------------------------------------------------------------- *)
(* Variable definition *)
(* ------------------------------------------------------------------------- *)
(* Also used for constant_definition with attrs = [Const].
 * Also used for field definition in a class (and record).
 * less: could use for function_definition with vinit = Some (Lambda (...))
 *  but maybe useful to explicitely makes the difference for now?
 *)
and variable_definition = {
  vinit: expr option;
  (* less: could merge in entity.type_ *)
  vtype: type_ option;
}

(* ------------------------------------------------------------------------- *)
(* Type definition *)
(* ------------------------------------------------------------------------- *)
and type_definition = {
   tbody: type_definition_kind;
  }

  and type_definition_kind = 
   | OrType  of or_type_element list  (* enum/ADTs *)           
   (* field.vtype should be defined here 
    * record/struct (for class see class_definition 
    *)
   | AndType of field list (* TODO bracket  *)

   (* a.k.a typedef in C (and alias type in Go) *)
   | AliasType of type_
   | Exception of ident (* same name than entity *) * type_ list

   | OtherTypeKind of other_type_kind_operator * any list

  and or_type_element =
    | OrConstructor of ident * type_ list
    | OrEnum of ident * expr
    | OrUnion of ident * type_

    | OtherOr of other_or_type_element_operator * any list

      and other_or_type_element_operator =
      (* Java *)
      | OOTEO_EnumWithMethods | OOTEO_EnumWithArguments

 (* Field definition and use, for classes and records
  * less: could be merged with variable_definition.
  * note: I don't call it field_definition because it's used both to
  * define the shape of a field (a definition), and when creating
  * an actual field (a value)
  *)
  and field = 
    | FieldVar of entity * variable_definition
    (* those can have empty body for interface methods *)
    | FieldMethod of entity * function_definition

    | FieldDynamic of expr (* dynamic name *) * attribute list * expr (*value*)
    | FieldSpread of tok (* ... *) * expr (* usually a Name *)

    | FieldStmt of stmt

  and other_type_kind_operator = 
     (* OCaml *)
     | OTKO_AbstractType
     (* Go *)
     | OTKO_Typedef (* type x foo (vs type x = foo) *)

(* ------------------------------------------------------------------------- *)
(* Class definition *)
(* ------------------------------------------------------------------------- *)
(* less: could be a special kind of type_definition *)
and class_definition = {
  ckind: class_kind;
  cextends: type_ list; (* usually just one parent *)
  cimplements: type_ list;
  (* newscope: *)
  cbody: field list; (* TODO bracket *)
}
  and class_kind = 
    | Class
    | Interface
    | Trait

(* ------------------------------------------------------------------------- *)
(* Module definition  *)
(* ------------------------------------------------------------------------- *)
and module_definition = {
  mbody: module_definition_kind;
}

  and module_definition_kind =
    | ModuleAlias of name
    (* newscope: *)
    | ModuleStruct of dotted_ident option * item list

    | OtherModule of other_module_operator * any list

  and other_module_operator =
   (* OCaml *)
   | OMO_Functor

(* ------------------------------------------------------------------------- *)
(* Macro definition *)
(* ------------------------------------------------------------------------- *)
and macro_definition = {
  macroparams: ident list;
  macrobody: any list;
}

(*****************************************************************************)
(* Directives (Module import/export, package) *)
(*****************************************************************************)
and directive = 
  (* newvar: *)
  | ImportFrom of tok (* 'import' or 'from' *) * module_name * alias list
     (* less: unfold the alias list? *)
  | ImportAs   of tok * module_name * ident option (* as name *)
  (* bad practice! hard to resolve name locally *)
  | ImportAll  of tok * module_name * tok (* '.' in Go, '*' in Java/Python *)

  (* packages are different from modules in that multiple files can reuse
   * the same package name; they are agglomarated in the same package
   *)
  | Package of tok * dotted_ident (* a.k.a namespace *)

  | OtherDirective of other_directive_operator * any list

  and alias = ident * ident option (* as name *)

  and other_directive_operator = 
  (* Javascript *)
  | OI_Export 
  | OI_ImportCss | OI_ImportEffect

(*****************************************************************************)
(* Toplevel *)
(*****************************************************************************)
(* item (a.k.a toplevel element, toplevel decl) is now equal to stmt.
 * Indeed, many languages allow nested functions
 * or class definitions and even nested imports, so this is simpler to
 * just merge them. 
 * This can simplify sgrep too.
 * less: merge with field?
 *)
and item = stmt

and program = item list

(*****************************************************************************)
(* Any *)
(*****************************************************************************)

(* mentioned in many OtherXxx so must be part of the mutually recursive type *)
and any =
  | Id of ident
  | N of name
  | En of entity

  | E of expr
  | S of stmt
  | T of type_
  | P of pattern

  | Def of definition
  | Dir of directive

  | Pa of parameter
  | Ar of argument
  | At of attribute
  | Dk of definition_kind
  | Di of dotted_ident
  | Fld of field
  | Ss of stmt list
  | Tk of tok

  | Pr of program

 (* with tarzan *)

(*****************************************************************************)
(* Wrappers *)
(*****************************************************************************)
let str_of_ident = fst

(*****************************************************************************)
(* Error *)
(*****************************************************************************)

(* this can be used in the xxx_to_generic.ml file to signal limitations,
 * and can be captured in Error_code.exn_to_error to pinpoint the error
 * location.
 *)
exception Error of string * Parse_info.t

let error tok msg = 
  raise (Error (msg, tok))

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* use 0 for globals, if needed *)
let gensym_counter = ref 0
(* see gensym type in resolved_name *)
let gensym () = 
  incr gensym_counter;
  !gensym_counter


let empty_name_info = 
  { name_qualifier = None; name_typeargs = None;}

let empty_var = 
  { vinit = None; vtype = None }

let empty_id_info () = 
  { id_resolved = ref None; id_type = ref None; }


let param_of_id id = { 
    pname = Some id;
    pdefault = None; ptype = None; pattrs = []; pinfo = empty_id_info ();
}
let param_of_type typ = {
    ptype = Some typ;
    pname = None; pdefault = None; pattrs = []; pinfo = empty_id_info ();
}

let basic_entity id attrs = {
  name = id;
  attrs = attrs;
  tparams = []; info = empty_id_info ();
}

let basic_field id typeopt =
  let entity = basic_entity id [] in
  FieldVar (entity, { vinit = None; vtype = typeopt})

let attr kwd tok =
  KeywordAttr (kwd, tok)

let expr_to_arg e = 
  Arg e
(* Should fix those, try to transform in PatLiteral/... when can.
 * Note that in Go it's ok to have a complex expressions. It is just
 * matched for equality with the thing it's matched against, so in that
 * case it should be a pattern like | _ when expr = x.
 *)
let expr_to_pattern e =
  (* TODO: diconstruct e and generate the right pattern (PatLiteral, ...) *)
  OtherPat (OP_ExprPattern, [E e])

(* see also Java_to_generic.entity_to_param *)
(* see also python_to_generic.expr_to_attribute *)

(* should avoid; should prefer to use 'expr option' in the AST *)
let opt_to_nop opt =
  match opt with
  | None -> Nop
  | Some e -> e

let opt_to_empty opt =
  match opt with
  | None -> Block []
  | Some e -> e

let stmt1 xs =
  match xs with
  | [] -> Block []
  | [st] -> st
  | xs -> Block xs

(* todo? sign that should merge field with item and stmt? *)
let stmt_to_field st = 
  match st with
  | DefStmt (entity, VarDef def) -> FieldVar (entity, def)
  | DefStmt (entity, FuncDef def) -> FieldMethod (entity, def)
  | _ -> FieldStmt st

let is_boolean_operator = function
 | Plus (* unary too *) | Minus (* unary too *) 
 | Mult | Div | Mod
 | Pow | FloorDiv | MatMult (* Python *)
 | LSL | LSR | ASR (* L = logic, A = Arithmetic, SL = shift left *) 
 | BitOr | BitXor | BitAnd | BitNot | BitClear (* unary *)
  -> false
 | And | Or | Xor | Not
 | Eq     | NotEq     
 | PhysEq | NotPhysEq 
 | Lt | LtE | Gt | GtE 
   -> true

let vardef_to_assign (ent, def) resolved =
  let idinfo = { (empty_id_info()) with id_resolved = ref resolved } in
  let name = Name ((ent.name, empty_name_info), idinfo) in
  let v = opt_to_nop def.vinit in
  Assign (name, Parse_info.fake_info "=", v)

let funcdef_to_lambda (ent, def) resolved =
  let idinfo = { (empty_id_info()) with id_resolved = ref resolved } in
  let name = Name ((ent.name, empty_name_info), idinfo) in
  let v = Lambda def in
  Assign (name, Parse_info.fake_info "=", v)
