(* Code for optimization passes on the MIR *)
open Core_kernel
open Mir
open Mir_utils

let create_function_inline_map l =
  (* We only add the first definition for each function to the inline map.
   This will make sure we do not inline recursive functions. *)
  let f accum {stmt; _} =
    match stmt with
    | FunDef {fdname; fdargs; fdbody; fdrt} -> (
      match
        Map.add accum ~key:fdname
          ~data:(fdrt, List.map ~f:(fun (_, name, _) -> name) fdargs, fdbody)
      with
      | `Ok m -> m
      | `Duplicate -> accum )
    | _ -> Errors.fatal_error ()
  in
  Map.filter
    ~f:(fun (_, _, v) -> v.stmt <> Skip)
    (List.fold l ~init:Map.Poly.empty ~f)

let replace_fresh_local_vars s' =
  let f m = function
    | Decl {decl_adtype; decl_type; decl_id} ->
        let fresh_name = Util.gensym () in
        ( Decl {decl_adtype; decl_id= fresh_name; decl_type}
        , Map.Poly.set m ~key:decl_id
            ~data:
              { texpr= Var fresh_name
              ; texpr_type= decl_type
              ; texpr_adlevel= decl_adtype
              ; texpr_loc= Mir.no_span } )
    | x -> (x, m)
  in
  let s, m = map_rec_state_stmt_loc f Map.Poly.empty s' in
  subst_stmt m s

let subst_args_stmt args es =
  let m = Map.Poly.of_alist_exn (List.zip_exn args es) in
  subst_stmt m

let handle_early_returns opt_triple b =
  let f = function
    | Return opt_ret -> (
      match (opt_triple, opt_ret) with
      | None, None -> Break
      | Some (Some rt, adt, name), Some e ->
          SList
            [ { stmt=
                  Assignment
                    ( { texpr= Var name
                      ; texpr_type= rt
                      ; texpr_loc= Mir.no_span
                      ; texpr_adlevel= adt }
                    , e )
              ; sloc= Mir.no_span }
            ; {stmt= Break; sloc= Mir.no_span} ]
      | _, _ -> Errors.fatal_error () )
    | x -> x
  in
  For
    { loopvar= Util.gensym ()
    ; lower=
        { texpr= Lit (Int, "1")
        ; texpr_type= UInt
        ; texpr_adlevel= DataOnly
        ; texpr_loc= Mir.no_span }
    ; upper=
        { texpr= Lit (Int, "1")
        ; texpr_type= UInt
        ; texpr_adlevel= DataOnly
        ; texpr_loc= Mir.no_span }
    ; body= map_rec_stmt_loc f b }

let map_no_loc l = List.map ~f:(fun s -> {stmt= s; sloc= Mir.no_span}) l
let slist_no_loc l = SList (map_no_loc l)

let slist_concat_no_loc l stmt =
  match l with [] -> stmt | l -> slist_no_loc (l @ [stmt])

let rec inline_function_statement adt fim {stmt; sloc} =
  { stmt=
      ( match stmt with
      | Assignment (e1, e2) ->
          let sl1, e1 = inline_function_expression adt fim e1 in
          let sl2, e2 = inline_function_expression adt fim e2 in
          slist_concat_no_loc (sl2 @ sl1) (Assignment (e1, e2))
      | TargetPE e ->
          let s, e = inline_function_expression adt fim e in
          slist_concat_no_loc s (TargetPE e)
      | NRFunApp (s, es) ->
          let se_list = List.map ~f:(inline_function_expression adt fim) es in
          (* function arguments are evaluated from right to left in C++, so we need to reverse *)
          let s_list = List.concat (List.rev (List.map ~f:fst se_list)) in
          let es = List.map ~f:snd se_list in
          slist_concat_no_loc s_list
            ( match Map.find fim s with
            | None -> NRFunApp (s, es)
            | Some (_, args, b) ->
                let b = replace_fresh_local_vars b in
                let b = handle_early_returns None b in
                (subst_args_stmt args es {stmt= b; sloc= Mir.no_span}).stmt )
      | Check (f, l) ->
          let se_list = List.map ~f:(inline_function_expression adt fim) l in
          let s_list = List.concat (List.rev (List.map ~f:fst se_list)) in
          let es = List.map ~f:snd se_list in
          slist_concat_no_loc s_list (Check (f, es))
      | Return e -> (
        match e with
        | None -> Return None
        | Some e ->
            let s, e = inline_function_expression adt fim e in
            slist_concat_no_loc s (Return (Some e)) )
      | IfElse (e, s1, s2) ->
          let s, e = inline_function_expression adt fim e in
          slist_concat_no_loc s
            (IfElse
               ( e
               , inline_function_statement adt fim s1
               , Option.map ~f:(inline_function_statement adt fim) s2 ))
      | While (e, s) ->
          let s', e = inline_function_expression adt fim e in
          slist_concat_no_loc s'
            (While
               ( e
               , match s' with
                 | [] -> inline_function_statement adt fim s
                 | _ ->
                     { stmt=
                         SList
                           ( [inline_function_statement adt fim s]
                           @ map_no_loc s' )
                     ; sloc= Mir.no_span } ))
      | For {loopvar; lower; upper; body} ->
          let s_lower, lower = inline_function_expression adt fim lower in
          let s_upper, upper = inline_function_expression adt fim upper in
          slist_concat_no_loc (s_lower @ s_upper)
            (For
               { loopvar
               ; lower
               ; upper
               ; body=
                   ( match s_upper with
                   | [] -> inline_function_statement adt fim body
                   | _ ->
                       { stmt=
                           SList
                             ( [inline_function_statement adt fim body]
                             @ map_no_loc s_upper )
                       ; sloc= Mir.no_span } ) })
      | Block l -> Block (List.map l ~f:(inline_function_statement adt fim))
      | SList l -> SList (List.map l ~f:(inline_function_statement adt fim))
      | FunDef {fdrt; fdname; fdargs; fdbody} ->
          FunDef
            { fdrt
            ; fdname
            ; fdargs
            ; fdbody= inline_function_statement adt fim fdbody }
      | Decl r -> Decl r
      | Skip -> Skip
      | Break -> Break
      | Continue -> Continue )
  ; sloc }

and inline_function_expression adt fim e =
  match e.texpr with
  | Var _ -> ([], e)
  | Lit (_, _) -> ([], e)
  | FunApp (s, es) -> (
      let se_list = List.map ~f:(inline_function_expression adt fim) es in
      let s_list = List.concat (List.rev (List.map ~f:fst se_list)) in
      let es = List.map ~f:snd se_list in
      match Map.find fim s with
      | None -> (s_list, e)
      | Some (rt, args, b) ->
          let b = replace_fresh_local_vars b in
          let x = Util.gensym () in
          let b = handle_early_returns (Some (rt, adt, x)) b in
          ( s_list
            @ [ Decl
                  {decl_adtype= adt; decl_id= x; decl_type= Option.value_exn rt}
              ; (subst_args_stmt args es {stmt= b; sloc= Mir.no_span}).stmt ]
          , { texpr= Var x
            ; texpr_type= Option.value_exn rt
            ; texpr_adlevel= adt
            ; texpr_loc= Mir.no_span } )
      (* TODO: really, || and && should be lazy here. *) )
  | TernaryIf (e1, e2, e3) ->
      let sl1, e1 = inline_function_expression adt fim e1 in
      let sl2, e2 = inline_function_expression adt fim e2 in
      let sl3, e3 = inline_function_expression adt fim e3 in
      ( sl1
        @ [ IfElse
              ( e1
              , {stmt= slist_no_loc sl2; sloc= Mir.no_span}
              , Some {stmt= slist_no_loc sl3; sloc= Mir.no_span} ) ]
      , {e with texpr= TernaryIf (e1, e2, e3); texpr_loc= Mir.no_span} )
  | Indexed (e, i_list) ->
      let sl, e = inline_function_expression adt fim e in
      let si_list = List.map ~f:(inline_function_index adt fim) i_list in
      let s_list = List.concat (List.rev (List.map ~f:fst si_list)) in
      (s_list @ sl, e)

and inline_function_index adt fim i =
  match i with
  | All -> ([], All)
  | Single e ->
      let sl, e = inline_function_expression adt fim e in
      (sl, Single e)
  | Upfrom e ->
      let sl, e = inline_function_expression adt fim e in
      (sl, Upfrom e)
  | Downfrom e ->
      let sl, e = inline_function_expression adt fim e in
      (sl, Downfrom e)
  | Between (e1, e2) ->
      let sl1, e1 = inline_function_expression adt fim e1 in
      let sl2, e2 = inline_function_expression adt fim e2 in
      (sl1 @ sl2, Between (e1, e2))
  | MultiIndex e ->
      let sl, e = inline_function_expression adt fim e in
      (sl, MultiIndex e)

let function_inlining (mir : typed_prog) =
  let function_inline_map = create_function_inline_map mir.functions_block in
  let inline_function_statements adt =
    List.map ~f:(inline_function_statement adt function_inline_map)
  in
  { functions_block= inline_function_statements Ast.DataOnly mir.functions_block
  ; data_vars= mir.data_vars
  ; tdata_vars= mir.tdata_vars
  ; prepare_data= inline_function_statements Ast.DataOnly mir.prepare_data
  ; params= mir.params
  ; tparams= mir.tparams
  ; prepare_params=
      inline_function_statements Ast.AutoDiffable mir.prepare_params
  ; log_prob= inline_function_statements Ast.AutoDiffable mir.log_prob
  ; gen_quant_vars= mir.gen_quant_vars
  ; generate_quantities=
      inline_function_statements Ast.DataOnly mir.generate_quantities
  ; prog_name= mir.prog_name
  ; prog_path= mir.prog_path }

let rec contains_top_break_or_continue {stmt; _} =
  match stmt with
  | Break | Continue -> true
  | Assignment (_, _)
   |TargetPE _
   |NRFunApp (_, _)
   |Check _ | Return _ | FunDef _ | Decl _
   |While (_, _)
   |For _ | Skip ->
      false
  | Block l | SList l -> List.exists l ~f:contains_top_break_or_continue
  | IfElse (_, b1, b2) -> (
      contains_top_break_or_continue b1
      ||
      match b2 with
      | None -> false
      | Some b -> contains_top_break_or_continue b )

let unroll_loops_statement =
  let f stmt =
    match stmt with
    | For {loopvar; lower; upper; body} -> (
      match
        (contains_top_break_or_continue body, lower.texpr, upper.texpr)
      with
      | false, Lit (Int, low), Lit (Int, up) ->
          let range =
            List.map
              ~f:(fun i ->
                { texpr= Lit (Int, Int.to_string i)
                ; texpr_type= UInt
                ; texpr_loc= Mir.no_span
                ; texpr_adlevel= DataOnly } )
              (List.range ~start:`inclusive ~stop:`inclusive
                 (Int.of_string low) (Int.of_string up))
          in
          let stmts =
            List.map
              ~f:(fun i ->
                subst_args_stmt [loopvar] [i]
                  {stmt= body.stmt; sloc= Mir.no_span} )
              range
          in
          SList stmts
      | _ -> stmt )
    | _ -> stmt
  in
  map_rec_stmt_loc f

let loop_unrolling = map_prog (fun x -> x) unroll_loops_statement

let collapse_lists_statement =
  let rec collapse_lists l =
    match l with
    | [] -> []
    | {stmt= SList l'; _} :: rest -> l' @ collapse_lists rest
    | x :: rest -> x :: collapse_lists rest
  in
  let f = function
    | Block l -> Block (collapse_lists l)
    | SList l -> SList (collapse_lists l)
    | x -> x
  in
  map_rec_stmt_loc f

let list_collapsing (mir : typed_prog) =
  map_prog (fun x -> x) collapse_lists_statement mir

let statement_of_program mir =
  { stmt=
      SList
        (List.map
           ~f:(fun x -> {stmt= SList x; sloc= Mir.no_span})
           [ mir.functions_block; mir.prepare_data; mir.prepare_params
           ; mir.log_prob; mir.generate_quantities ])
  ; sloc= Mir.no_span }

let update_program_statement_blocks (mir : typed_prog) (s : stmt_loc) =
  let l =
    match s.stmt with
    | SList l ->
        List.map
          ~f:(fun x ->
            match x.stmt with
            | SList l -> l
            | _ -> raise_s [%sexp (x : stmt_loc)] )
          l
    | _ -> raise_s [%sexp (s : stmt_loc)]
  in
  { mir with
    functions_block= List.nth_exn l 0
  ; prepare_data= List.nth_exn l 1
  ; prepare_params= List.nth_exn l 2
  ; log_prob= List.nth_exn l 3
  ; generate_quantities= List.nth_exn l 4 }

let propagation
    (propagation_transfer :
         (int, Mir.stmt_loc_num) Map.Poly.t
      -> (module
          Monotone_framework_sigs.TRANSFER_FUNCTION
            with type labels = int
             and type properties = (string, Mir.expr_typed_located) Map.Poly.t
                                   option)) (mir : typed_prog) =
  let s = statement_of_program mir in
  let flowgraph, flowgraph_to_mir =
    Monotone_framework.forward_flowgraph_of_stmt s
  in
  let (module Flowgraph) = flowgraph in
  let values =
    Monotone_framework.propagation_mfp mir
      (module Flowgraph)
      flowgraph_to_mir propagation_transfer
  in
  let propagate_stmt =
    map_rec_stmt_loc_num flowgraph_to_mir (fun i ->
        subst_stmt_base
          (Option.value ~default:Map.Poly.empty (Map.find_exn values i).entry)
    )
  in
  let s = propagate_stmt (Map.find_exn flowgraph_to_mir 1) in
  update_program_statement_blocks mir s

let constant_propagation =
  propagation Monotone_framework.constant_propagation_transfer

let expression_propagation =
  propagation Monotone_framework.expression_propagation_transfer

let copy_propagation = propagation Monotone_framework.copy_propagation_transfer

let rec can_side_effect_expr (e : expr_typed_located) =
  match e.texpr with
  | Var _ | Lit (_, _) -> false
  | FunApp (f, es) ->
      String.suffix f 3 = "_lp" || List.exists ~f:can_side_effect_expr es
  | TernaryIf (e1, e2, e3) -> List.exists ~f:can_side_effect_expr [e1; e2; e3]
  | Indexed (e, is) ->
      can_side_effect_expr e || List.exists ~f:can_side_effect_idx is

and can_side_effect_idx (i : expr_typed_located index) =
  match i with
  | All -> false
  | Single e | Upfrom e | Downfrom e | MultiIndex e -> can_side_effect_expr e
  | Between (e1, e2) -> can_side_effect_expr e1 || can_side_effect_expr e2

let is_skip_break_continue s =
  match s with Skip | Break | Continue -> true | _ -> false

(* TODO: could also implement partial dead code elimination *)
let dead_code_elimination (mir : typed_prog) =
  (* TODO: think about whether we should treat function bodies as local scopes in the statement
   from the POV of a live variables analysis.
   (Obviously, this shouldn't be the case for the purposes of reaching definitions,
   constant propagation, expressions analyses. But I do think that's the right way to
   go about live variables. *)
  let s = statement_of_program mir in
  let rev_flowgraph, flowgraph_to_mir =
    Monotone_framework.inverse_flowgraph_of_stmt s
  in
  let (module Rev_Flowgraph) = rev_flowgraph in
  let live_variables =
    Monotone_framework.live_variables_mfp mir
      (module Rev_Flowgraph)
      flowgraph_to_mir
  in
  let dead_code_elim_stmt_base i stmt =
    (* NOTE: entry in the reverse flowgraph, so exit in the forward flowgraph *)
    let live_variables_s =
      (Map.find_exn live_variables i).Monotone_framework_sigs.entry
    in
    match stmt with
    | Assignment ({texpr= Var x; _}, rhs) ->
        if Set.Poly.mem live_variables_s x || can_side_effect_expr rhs then
          stmt
        else Skip
    | Assignment ({texpr= Indexed ({texpr= Var x; _}, is); _}, rhs) ->
        if
          Set.Poly.mem live_variables_s x
          || can_side_effect_expr rhs
          || List.exists ~f:can_side_effect_idx is
        then stmt
        else Skip
    | Assignment _ -> Errors.fatal_error ()
    (* NOTE: we never get rid of declarations as we might not be able to remove an assignment to a variable
           due to side effects. *)
    | Decl _ | TargetPE _
     |NRFunApp (_, _)
     |Check _ | Break | Continue | Return _ | Skip ->
        stmt
    | IfElse (e, b1, b2) -> (
        if
          (* TODO: check if e has side effects, like print, reject, then don't optimize? *)
          (not (can_side_effect_expr e))
          && b1.stmt = Skip
          && ( Option.map ~f:(fun x -> x.stmt) b2 = Some Skip
             || Option.map ~f:(fun x -> x.stmt) b2 = None )
        then Skip
        else
          match e.texpr with
          | Lit (Int, "0") | Lit (Real, "0.0") -> (
            match b2 with Some x -> x.stmt | None -> Skip )
          | Lit (_, _) -> b1.stmt
          | _ -> IfElse (e, b1, b2) )
    | While (e, b) -> (
      match e.texpr with
      | Lit (Int, "0") | Lit (Real, "0.0") -> Skip
      | _ -> While (e, b) )
    | For {loopvar; lower; upper; body} ->
        (* TODO: check if e has side effects, like print, reject, then don't optimize? *)
        if
          (not (can_side_effect_expr lower))
          && (not (can_side_effect_expr upper))
          && is_skip_break_continue body.stmt
        then Skip
        else For {loopvar; lower; upper; body}
    | Block l ->
        let l' = List.filter ~f:(fun x -> x.stmt <> Skip) l in
        if List.length l' = 0 then Skip else Block l'
    | SList l ->
        let l' = List.filter ~f:(fun x -> x.stmt <> Skip) l in
        SList l'
    (* TODO: do dead code elimination in function body too! *)
    | FunDef x -> FunDef x
  in
  let dead_code_elim_stmt =
    map_rec_stmt_loc_num flowgraph_to_mir dead_code_elim_stmt_base
  in
  let s = dead_code_elim_stmt (Map.find_exn flowgraph_to_mir 1) in
  let mir = update_program_statement_blocks mir s in
  mir

let partial_evaluation = Partial_evaluator.eval_prog

(* TODO: implement SlicStan style optimizer for choosing best program block for each statement. *)
(* TODO: implement lazy code motion. Make sure to apply it separately to each program block, rather than to the program as a whole. *)
(* TODO: or maybe combine the previous two *)

(* TODO: add tests *)

let%expect_test "map_rec_stmt_loc" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        print(24);
        if (13) {
          print(244);
          if (24) {
            print(24);
          }
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let f = function
    | NRFunApp ("print", [s]) -> NRFunApp ("print", [s; s])
    | x -> x
  in
  let mir = map_prog (fun x -> x) (map_rec_stmt_loc f) mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 24))
              (texpr_adlevel DataOnly))
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 24))
              (texpr_adlevel DataOnly))))))
         ((sloc <opaque>)
          (stmt
           (IfElse
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 13))
             (texpr_adlevel DataOnly))
            ((sloc <opaque>)
             (stmt
              (Block
               (((sloc <opaque>)
                 (stmt
                  (NRFunApp print
                   (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 244))
                     (texpr_adlevel DataOnly))
                    ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 244))
                     (texpr_adlevel DataOnly))))))
                ((sloc <opaque>)
                 (stmt
                  (IfElse
                   ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 24))
                    (texpr_adlevel DataOnly))
                   ((sloc <opaque>)
                    (stmt
                     (Block
                      (((sloc <opaque>)
                        (stmt
                         (NRFunApp print
                          (((texpr_type UInt) (texpr_loc <opaque>)
                            (texpr (Lit Int 24)) (texpr_adlevel DataOnly))
                           ((texpr_type UInt) (texpr_loc <opaque>)
                            (texpr (Lit Int 24)) (texpr_adlevel DataOnly))))))))))
                   ())))))))
            ())))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "map_rec_stmt_loc" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        print(24);
        if (13) {
          print(244);
          if (24) {
            print(24);
          }
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let f i = function
    | NRFunApp ("print", [s]) -> (NRFunApp ("print", [s; s]), i + 1)
    | x -> (x, i)
  in
  let mir_num =
    (map_rec_state_stmt_loc f 0) {stmt= SList mir.log_prob; sloc= Mir.no_span}
  in
  print_s [%sexp (mir_num : stmt_loc * int)] ;
  [%expect
    {|
      (((sloc <opaque>)
        (stmt
         (SList
          (((sloc <opaque>)
            (stmt
             (NRFunApp print
              (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 24))
                (texpr_adlevel DataOnly))
               ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 24))
                (texpr_adlevel DataOnly))))))
           ((sloc <opaque>)
            (stmt
             (IfElse
              ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 13))
               (texpr_adlevel DataOnly))
              ((sloc <opaque>)
               (stmt
                (Block
                 (((sloc <opaque>)
                   (stmt
                    (NRFunApp print
                     (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 244))
                       (texpr_adlevel DataOnly))
                      ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 244))
                       (texpr_adlevel DataOnly))))))
                  ((sloc <opaque>)
                   (stmt
                    (IfElse
                     ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 24))
                      (texpr_adlevel DataOnly))
                     ((sloc <opaque>)
                      (stmt
                       (Block
                        (((sloc <opaque>)
                          (stmt
                           (NRFunApp print
                            (((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Lit Int 24)) (texpr_adlevel DataOnly))
                             ((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Lit Int 24)) (texpr_adlevel DataOnly))))))))))
                     ())))))))
              ())))))))
       3) |}]

let%expect_test "inline functions" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        void f(int x, matrix y) {
          print(x);
          print(y);
        }
        real g(int z) {
          return z^2;
        }
      }
      model {
        f(3, [[3,2],[4,6]]);
        reject(g(53));
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt ()) (fdname f)
            (fdargs ((AutoDiffable x UInt) (AutoDiffable y UMatrix)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var x))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UMatrix) (texpr_loc <opaque>) (texpr (Var y))
                      (texpr_adlevel AutoDiffable))))))))))))))
         ((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UReal)) (fdname g) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UReal) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Pow__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (For (loopvar sym1__)
            (lower
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
              (texpr_adlevel DataOnly)))
            (upper
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
              (texpr_adlevel DataOnly)))
            (body
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UMatrix) (texpr_loc <opaque>)
                      (texpr
                       (FunApp make_rowvec
                        (((texpr_type URowVector) (texpr_loc <opaque>)
                          (texpr
                           (FunApp make_rowvec
                            (((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Lit Int 3)) (texpr_adlevel DataOnly))
                             ((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                          (texpr_adlevel DataOnly))
                         ((texpr_type URowVector) (texpr_loc <opaque>)
                          (texpr
                           (FunApp make_rowvec
                            (((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Lit Int 4)) (texpr_adlevel DataOnly))
                             ((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Lit Int 6)) (texpr_adlevel DataOnly)))))
                          (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))
         ((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id sym2__) (decl_type UReal))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar sym3__)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (SList
                        (((sloc <opaque>)
                          (stmt
                           (Assignment
                            ((texpr_type UReal) (texpr_loc <opaque>)
                             (texpr (Var sym2__)) (texpr_adlevel AutoDiffable))
                            ((texpr_type UReal) (texpr_loc <opaque>)
                             (texpr
                              (FunApp Pow__
                               (((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 53)) (texpr_adlevel DataOnly))
                                ((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                             (texpr_adlevel DataOnly)))))
                         ((sloc <opaque>) (stmt Break))))))))))))))
             ((sloc <opaque>)
              (stmt
               (NRFunApp reject
                (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Var sym2__))
                  (texpr_adlevel AutoDiffable))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "list collapsing" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        void f(int x, matrix y) {
          print(x);
          print(y);
        }
        real g(int z) {
          return z^2;
        }
      }
      model {
        f(3, [[3,2],[4,6]]);
        reject(g(53));
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  let mir = list_collapsing mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
    ((functions_block
      (((sloc <opaque>)
        (stmt
         (FunDef (fdrt ()) (fdname f)
          (fdargs ((AutoDiffable x UInt) (AutoDiffable y UMatrix)))
          (fdbody
           ((sloc <opaque>)
            (stmt
             (Block
              (((sloc <opaque>)
                (stmt
                 (NRFunApp print
                  (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var x))
                    (texpr_adlevel DataOnly))))))
               ((sloc <opaque>)
                (stmt
                 (NRFunApp print
                  (((texpr_type UMatrix) (texpr_loc <opaque>) (texpr (Var y))
                    (texpr_adlevel AutoDiffable))))))))))))))
       ((sloc <opaque>)
        (stmt
         (FunDef (fdrt (UReal)) (fdname g) (fdargs ((AutoDiffable z UInt)))
          (fdbody
           ((sloc <opaque>)
            (stmt
             (Block
              (((sloc <opaque>)
                (stmt
                 (Return
                  (((texpr_type UReal) (texpr_loc <opaque>)
                    (texpr
                     (FunApp Pow__
                      (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                        (texpr_adlevel DataOnly))
                       ((texpr_type UInt) (texpr_loc <opaque>)
                        (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                    (texpr_adlevel DataOnly))))))))))))))))
     (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
     (prepare_params ())
     (log_prob
      (((sloc <opaque>)
        (stmt
         (For (loopvar sym4__)
          (lower
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
            (texpr_adlevel DataOnly)))
          (upper
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
            (texpr_adlevel DataOnly)))
          (body
           ((sloc <opaque>)
            (stmt
             (Block
              (((sloc <opaque>)
                (stmt
                 (NRFunApp print
                  (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                    (texpr_adlevel DataOnly))))))
               ((sloc <opaque>)
                (stmt
                 (NRFunApp print
                  (((texpr_type UMatrix) (texpr_loc <opaque>)
                    (texpr
                     (FunApp make_rowvec
                      (((texpr_type URowVector) (texpr_loc <opaque>)
                        (texpr
                         (FunApp make_rowvec
                          (((texpr_type UInt) (texpr_loc <opaque>)
                            (texpr (Lit Int 3)) (texpr_adlevel DataOnly))
                           ((texpr_type UInt) (texpr_loc <opaque>)
                            (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                        (texpr_adlevel DataOnly))
                       ((texpr_type URowVector) (texpr_loc <opaque>)
                        (texpr
                         (FunApp make_rowvec
                          (((texpr_type UInt) (texpr_loc <opaque>)
                            (texpr (Lit Int 4)) (texpr_adlevel DataOnly))
                           ((texpr_type UInt) (texpr_loc <opaque>)
                            (texpr (Lit Int 6)) (texpr_adlevel DataOnly)))))
                        (texpr_adlevel DataOnly)))))
                    (texpr_adlevel DataOnly))))))))))))))
       ((sloc <opaque>)
        (stmt
         (SList
          (((sloc <opaque>)
            (stmt
             (Decl (decl_adtype AutoDiffable) (decl_id sym5__) (decl_type UReal))))
           ((sloc <opaque>)
            (stmt
             (For (loopvar sym6__)
              (lower
               ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                (texpr_adlevel DataOnly)))
              (upper
               ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                (texpr_adlevel DataOnly)))
              (body
               ((sloc <opaque>)
                (stmt
                 (Block
                  (((sloc <opaque>)
                    (stmt
                     (Assignment
                      ((texpr_type UReal) (texpr_loc <opaque>)
                       (texpr (Var sym5__)) (texpr_adlevel AutoDiffable))
                      ((texpr_type UReal) (texpr_loc <opaque>)
                       (texpr
                        (FunApp Pow__
                         (((texpr_type UInt) (texpr_loc <opaque>)
                           (texpr (Lit Int 53)) (texpr_adlevel DataOnly))
                          ((texpr_type UInt) (texpr_loc <opaque>)
                           (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                       (texpr_adlevel DataOnly)))))
                   ((sloc <opaque>) (stmt Break))))))))))
           ((sloc <opaque>)
            (stmt
             (NRFunApp reject
              (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Var sym5__))
                (texpr_adlevel AutoDiffable))))))))))))
     (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path ""))
    |}]

let%expect_test "do not inline recursive functions" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        real g(int z);
        real g(int z) {
          return z^2;
        }
      }
      model {
        reject(g(53));
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UReal)) (fdname g) (fdargs ((AutoDiffable z UInt)))
            (fdbody ((sloc <opaque>) (stmt Skip))))))
         ((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UReal)) (fdname g) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UReal) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Pow__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (NRFunApp reject
            (((texpr_type UReal) (texpr_loc <opaque>)
              (texpr
               (FunApp g
                (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 53))
                  (texpr_adlevel DataOnly)))))
              (texpr_adlevel DataOnly))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "inline function in for loop" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        int f(int z) {
          print("f");
          return 42;
        }
        int g(int z) {
          print("g");
          return z + 24;
        }
      }
      model {
        for (i in f(2) : g(3)) print("body");
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname f) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str f))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
                      (texpr_adlevel DataOnly))))))))))))))
         ((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname g) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str g))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Plus__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 24)) (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id sym7__) (decl_type UInt))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar sym8__)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UReal) (texpr_loc <opaque>)
                          (texpr (Lit Str f)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>)
                      (stmt
                       (SList
                        (((sloc <opaque>)
                          (stmt
                           (Assignment
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Var sym7__)) (texpr_adlevel AutoDiffable))
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Lit Int 42)) (texpr_adlevel DataOnly)))))
                         ((sloc <opaque>) (stmt Break))))))))))))))
             ((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id sym9__) (decl_type UInt))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar sym10__)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UReal) (texpr_loc <opaque>)
                          (texpr (Lit Str g)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>)
                      (stmt
                       (SList
                        (((sloc <opaque>)
                          (stmt
                           (Assignment
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Var sym9__)) (texpr_adlevel AutoDiffable))
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr
                              (FunApp Plus__
                               (((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 3)) (texpr_adlevel DataOnly))
                                ((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 24)) (texpr_adlevel DataOnly)))))
                             (texpr_adlevel DataOnly)))))
                         ((sloc <opaque>) (stmt Break))))))))))))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar i)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym7__))
                  (texpr_adlevel AutoDiffable)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym9__))
                  (texpr_adlevel AutoDiffable)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (SList
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UReal) (texpr_loc <opaque>)
                          (texpr (Lit Str body)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>)
                      (stmt
                       (Decl (decl_adtype AutoDiffable) (decl_id sym9__)
                        (decl_type UInt))))
                     ((sloc <opaque>)
                      (stmt
                       (For (loopvar sym10__)
                        (lower
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 1)) (texpr_adlevel DataOnly)))
                        (upper
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 1)) (texpr_adlevel DataOnly)))
                        (body
                         ((sloc <opaque>)
                          (stmt
                           (Block
                            (((sloc <opaque>)
                              (stmt
                               (NRFunApp print
                                (((texpr_type UReal) (texpr_loc <opaque>)
                                  (texpr (Lit Str g)) (texpr_adlevel DataOnly))))))
                             ((sloc <opaque>)
                              (stmt
                               (SList
                                (((sloc <opaque>)
                                  (stmt
                                   (Assignment
                                    ((texpr_type UInt) (texpr_loc <opaque>)
                                     (texpr (Var sym9__))
                                     (texpr_adlevel AutoDiffable))
                                    ((texpr_type UInt) (texpr_loc <opaque>)
                                     (texpr
                                      (FunApp Plus__
                                       (((texpr_type UInt) (texpr_loc <opaque>)
                                         (texpr (Lit Int 3))
                                         (texpr_adlevel DataOnly))
                                        ((texpr_type UInt) (texpr_loc <opaque>)
                                         (texpr (Lit Int 24))
                                         (texpr_adlevel DataOnly)))))
                                     (texpr_adlevel DataOnly)))))
                                 ((sloc <opaque>) (stmt Break))))))))))))))))))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "inline function in while loop" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        int f(int z) {
          print("f");
          return 42;
        }
        int g(int z) {
          print("g");
          return z + 24;
        }
      }
      model {
        while (g(3)) print("body");
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname f) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str f))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
                      (texpr_adlevel DataOnly))))))))))))))
         ((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname g) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str g))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Plus__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 24)) (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id sym11__) (decl_type UInt))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar sym12__)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UReal) (texpr_loc <opaque>)
                          (texpr (Lit Str g)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>)
                      (stmt
                       (SList
                        (((sloc <opaque>)
                          (stmt
                           (Assignment
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Var sym11__)) (texpr_adlevel AutoDiffable))
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr
                              (FunApp Plus__
                               (((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 3)) (texpr_adlevel DataOnly))
                                ((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 24)) (texpr_adlevel DataOnly)))))
                             (texpr_adlevel DataOnly)))))
                         ((sloc <opaque>) (stmt Break))))))))))))))
             ((sloc <opaque>)
              (stmt
               (While
                ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym11__))
                 (texpr_adlevel AutoDiffable))
                ((sloc <opaque>)
                 (stmt
                  (SList
                   (((sloc <opaque>)
                     (stmt
                      (NRFunApp print
                       (((texpr_type UReal) (texpr_loc <opaque>)
                         (texpr (Lit Str body)) (texpr_adlevel DataOnly))))))
                    ((sloc <opaque>)
                     (stmt
                      (Decl (decl_adtype AutoDiffable) (decl_id sym11__)
                       (decl_type UInt))))
                    ((sloc <opaque>)
                     (stmt
                      (For (loopvar sym12__)
                       (lower
                        ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                         (texpr_adlevel DataOnly)))
                       (upper
                        ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                         (texpr_adlevel DataOnly)))
                       (body
                        ((sloc <opaque>)
                         (stmt
                          (Block
                           (((sloc <opaque>)
                             (stmt
                              (NRFunApp print
                               (((texpr_type UReal) (texpr_loc <opaque>)
                                 (texpr (Lit Str g)) (texpr_adlevel DataOnly))))))
                            ((sloc <opaque>)
                             (stmt
                              (SList
                               (((sloc <opaque>)
                                 (stmt
                                  (Assignment
                                   ((texpr_type UInt) (texpr_loc <opaque>)
                                    (texpr (Var sym11__))
                                    (texpr_adlevel AutoDiffable))
                                   ((texpr_type UInt) (texpr_loc <opaque>)
                                    (texpr
                                     (FunApp Plus__
                                      (((texpr_type UInt) (texpr_loc <opaque>)
                                        (texpr (Lit Int 3))
                                        (texpr_adlevel DataOnly))
                                       ((texpr_type UInt) (texpr_loc <opaque>)
                                        (texpr (Lit Int 24))
                                        (texpr_adlevel DataOnly)))))
                                    (texpr_adlevel DataOnly)))))
                                ((sloc <opaque>) (stmt Break)))))))))))))))))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "inline function in if then else" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        int f(int z) {
          print("f");
          return 42;
        }
        int g(int z) {
          print("g");
          return z + 24;
        }
      }
      model {
        if (g(3)) print("body");
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname f) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str f))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
                      (texpr_adlevel DataOnly))))))))))))))
         ((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname g) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str g))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Plus__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 24)) (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id sym13__) (decl_type UInt))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar sym14__)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UReal) (texpr_loc <opaque>)
                          (texpr (Lit Str g)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>)
                      (stmt
                       (SList
                        (((sloc <opaque>)
                          (stmt
                           (Assignment
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Var sym13__)) (texpr_adlevel AutoDiffable))
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr
                              (FunApp Plus__
                               (((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 3)) (texpr_adlevel DataOnly))
                                ((texpr_type UInt) (texpr_loc <opaque>)
                                 (texpr (Lit Int 24)) (texpr_adlevel DataOnly)))))
                             (texpr_adlevel DataOnly)))))
                         ((sloc <opaque>) (stmt Break))))))))))))))
             ((sloc <opaque>)
              (stmt
               (IfElse
                ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym13__))
                 (texpr_adlevel AutoDiffable))
                ((sloc <opaque>)
                 (stmt
                  (NRFunApp print
                   (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str body))
                     (texpr_adlevel DataOnly))))))
                ())))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path ""))

    |}]

let%expect_test "inline function in ternary if " =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        int f(int z) {
          print("f");
          return 42;
        }
        int g(int z) {
          print("g");
          return z + 24;
        }
        int h(int z) {
          print("h");
          return z + 4;
        }
      }
      model {
        print(f(2) ? g(3) : h(4));
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname f) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str f))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
                      (texpr_adlevel DataOnly))))))))))))))
         ((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname g) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str g))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Plus__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 24)) (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))
         ((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname h) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str h))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Plus__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var z))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 4)) (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id sym15__) (decl_type UInt))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar sym16__)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UReal) (texpr_loc <opaque>)
                          (texpr (Lit Str f)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>)
                      (stmt
                       (SList
                        (((sloc <opaque>)
                          (stmt
                           (Assignment
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Var sym15__)) (texpr_adlevel AutoDiffable))
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Lit Int 42)) (texpr_adlevel DataOnly)))))
                         ((sloc <opaque>) (stmt Break))))))))))))))
             ((sloc <opaque>)
              (stmt
               (IfElse
                ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym15__))
                 (texpr_adlevel AutoDiffable))
                ((sloc <opaque>)
                 (stmt
                  (SList
                   (((sloc <opaque>)
                     (stmt
                      (Decl (decl_adtype AutoDiffable) (decl_id sym17__)
                       (decl_type UInt))))
                    ((sloc <opaque>)
                     (stmt
                      (For (loopvar sym18__)
                       (lower
                        ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                         (texpr_adlevel DataOnly)))
                       (upper
                        ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                         (texpr_adlevel DataOnly)))
                       (body
                        ((sloc <opaque>)
                         (stmt
                          (Block
                           (((sloc <opaque>)
                             (stmt
                              (NRFunApp print
                               (((texpr_type UReal) (texpr_loc <opaque>)
                                 (texpr (Lit Str g)) (texpr_adlevel DataOnly))))))
                            ((sloc <opaque>)
                             (stmt
                              (SList
                               (((sloc <opaque>)
                                 (stmt
                                  (Assignment
                                   ((texpr_type UInt) (texpr_loc <opaque>)
                                    (texpr (Var sym17__))
                                    (texpr_adlevel AutoDiffable))
                                   ((texpr_type UInt) (texpr_loc <opaque>)
                                    (texpr
                                     (FunApp Plus__
                                      (((texpr_type UInt) (texpr_loc <opaque>)
                                        (texpr (Lit Int 3))
                                        (texpr_adlevel DataOnly))
                                       ((texpr_type UInt) (texpr_loc <opaque>)
                                        (texpr (Lit Int 24))
                                        (texpr_adlevel DataOnly)))))
                                    (texpr_adlevel DataOnly)))))
                                ((sloc <opaque>) (stmt Break))))))))))))))))))
                (((sloc <opaque>)
                  (stmt
                   (SList
                    (((sloc <opaque>)
                      (stmt
                       (Decl (decl_adtype AutoDiffable) (decl_id sym19__)
                        (decl_type UInt))))
                     ((sloc <opaque>)
                      (stmt
                       (For (loopvar sym20__)
                        (lower
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 1)) (texpr_adlevel DataOnly)))
                        (upper
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 1)) (texpr_adlevel DataOnly)))
                        (body
                         ((sloc <opaque>)
                          (stmt
                           (Block
                            (((sloc <opaque>)
                              (stmt
                               (NRFunApp print
                                (((texpr_type UReal) (texpr_loc <opaque>)
                                  (texpr (Lit Str h)) (texpr_adlevel DataOnly))))))
                             ((sloc <opaque>)
                              (stmt
                               (SList
                                (((sloc <opaque>)
                                  (stmt
                                   (Assignment
                                    ((texpr_type UInt) (texpr_loc <opaque>)
                                     (texpr (Var sym19__))
                                     (texpr_adlevel AutoDiffable))
                                    ((texpr_type UInt) (texpr_loc <opaque>)
                                     (texpr
                                      (FunApp Plus__
                                       (((texpr_type UInt) (texpr_loc <opaque>)
                                         (texpr (Lit Int 4))
                                         (texpr_adlevel DataOnly))
                                        ((texpr_type UInt) (texpr_loc <opaque>)
                                         (texpr (Lit Int 4))
                                         (texpr_adlevel DataOnly)))))
                                     (texpr_adlevel DataOnly)))))
                                 ((sloc <opaque>) (stmt Break))))))))))))))))))))))
             ((sloc <opaque>)
              (stmt
               (NRFunApp print
                (((texpr_type UInt) (texpr_loc <opaque>)
                  (texpr
                   (TernaryIf
                    ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym15__))
                     (texpr_adlevel AutoDiffable))
                    ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym17__))
                     (texpr_adlevel AutoDiffable))
                    ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym19__))
                     (texpr_adlevel AutoDiffable))))
                  (texpr_adlevel DataOnly))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "inline function in ternary if " =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        int f(int z) {
          if (2) {
            print("f");
            return 42;
          }
          return 6;
        }
      }
      model {
        print(f(2));
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = function_inlining mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UInt)) (fdname f) (fdargs ((AutoDiffable z UInt)))
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (IfElse
                    ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                     (texpr_adlevel DataOnly))
                    ((sloc <opaque>)
                     (stmt
                      (Block
                       (((sloc <opaque>)
                         (stmt
                          (NRFunApp print
                           (((texpr_type UReal) (texpr_loc <opaque>)
                             (texpr (Lit Str f)) (texpr_adlevel DataOnly))))))
                        ((sloc <opaque>)
                         (stmt
                          (Return
                           (((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Lit Int 42)) (texpr_adlevel DataOnly))))))))))
                    ())))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 6))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id sym21__) (decl_type UInt))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar sym22__)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (IfElse
                        ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                         (texpr_adlevel DataOnly))
                        ((sloc <opaque>)
                         (stmt
                          (Block
                           (((sloc <opaque>)
                             (stmt
                              (NRFunApp print
                               (((texpr_type UReal) (texpr_loc <opaque>)
                                 (texpr (Lit Str f)) (texpr_adlevel DataOnly))))))
                            ((sloc <opaque>)
                             (stmt
                              (SList
                               (((sloc <opaque>)
                                 (stmt
                                  (Assignment
                                   ((texpr_type UInt) (texpr_loc <opaque>)
                                    (texpr (Var sym21__))
                                    (texpr_adlevel AutoDiffable))
                                   ((texpr_type UInt) (texpr_loc <opaque>)
                                    (texpr (Lit Int 42)) (texpr_adlevel DataOnly)))))
                                ((sloc <opaque>) (stmt Break))))))))))
                        ())))
                     ((sloc <opaque>)
                      (stmt
                       (SList
                        (((sloc <opaque>)
                          (stmt
                           (Assignment
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Var sym21__)) (texpr_adlevel AutoDiffable))
                            ((texpr_type UInt) (texpr_loc <opaque>)
                             (texpr (Lit Int 6)) (texpr_adlevel DataOnly)))))
                         ((sloc <opaque>) (stmt Break))))))))))))))
             ((sloc <opaque>)
              (stmt
               (NRFunApp print
                (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var sym21__))
                  (texpr_adlevel AutoDiffable))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "unroll nested loop" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|      model {
                for (i in 1:2)
                  for (j in 3:4)
                    print(i, j);
                   }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = loop_unrolling mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (SList
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                      (texpr_adlevel DataOnly))
                     ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                      (texpr_adlevel DataOnly))
                     ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 4))
                      (texpr_adlevel DataOnly))))))))))
             ((sloc <opaque>)
              (stmt
               (SList
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                      (texpr_adlevel DataOnly))
                     ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                      (texpr_adlevel DataOnly))))))
                 ((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                      (texpr_adlevel DataOnly))
                     ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 4))
                      (texpr_adlevel DataOnly))))))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "unroll nested loop with break" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|      model {
                for (i in 1:2)
                  for (j in 3:4) {
                    print(i);
                    break;
                  }
              }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = loop_unrolling mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (For (loopvar j)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 4))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 1)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>) (stmt Break))))))))))
             ((sloc <opaque>)
              (stmt
               (For (loopvar j)
                (lower
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                  (texpr_adlevel DataOnly)))
                (upper
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 4))
                  (texpr_adlevel DataOnly)))
                (body
                 ((sloc <opaque>)
                  (stmt
                   (Block
                    (((sloc <opaque>)
                      (stmt
                       (NRFunApp print
                        (((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr (Lit Int 2)) (texpr_adlevel DataOnly))))))
                     ((sloc <opaque>) (stmt Break))))))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "constant propagation" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      transformed data {
        int i;
        i = 42;
        int j;
        j = 2 + i;
      }
      model {
        for (x in 1:i) {
          print(i + j);
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = constant_propagation mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
    ((functions_block ()) (data_vars ())
     (tdata_vars
      ((i ((tvident i) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))
       (j ((tvident j) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))))
     (prepare_data
      (((sloc <opaque>)
        (stmt
         (Assignment
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
           (texpr_adlevel DataOnly))
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
           (texpr_adlevel DataOnly)))))
       ((sloc <opaque>)
        (stmt
         (Assignment
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var j))
           (texpr_adlevel DataOnly))
          ((texpr_type UInt) (texpr_loc <opaque>)
           (texpr
            (FunApp Plus__
             (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
               (texpr_adlevel DataOnly))
              ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
               (texpr_adlevel DataOnly)))))
           (texpr_adlevel DataOnly)))))))
     (params ()) (tparams ()) (prepare_params ())
     (log_prob
      (((sloc <opaque>)
        (stmt
         (For (loopvar x)
          (lower
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
            (texpr_adlevel DataOnly)))
          (upper
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
            (texpr_adlevel DataOnly)))
          (body
           ((sloc <opaque>)
            (stmt
             (Block
              (((sloc <opaque>)
                (stmt
                 (NRFunApp print
                  (((texpr_type UInt) (texpr_loc <opaque>)
                    (texpr
                     (FunApp Plus__
                      (((texpr_type UInt) (texpr_loc <opaque>)
                        (texpr (Lit Int 42)) (texpr_adlevel DataOnly))
                       ((texpr_type UInt) (texpr_loc <opaque>)
                        (texpr (Lit Int 44)) (texpr_adlevel DataOnly)))))
                    (texpr_adlevel DataOnly))))))))))))))))
     (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "constant propagation, local scope" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      transformed data {
        int i;
        i = 42;
        {
          int j;
          j = 2;
        }
      }
      model {
        int j;
        for (x in 1:i) {
          print(i + j);
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = constant_propagation mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
    ((functions_block ()) (data_vars ())
     (tdata_vars
      ((i ((tvident i) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))))
     (prepare_data
      (((sloc <opaque>)
        (stmt
         (Assignment
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
           (texpr_adlevel DataOnly))
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
           (texpr_adlevel DataOnly)))))
       ((sloc <opaque>)
        (stmt
         (Block
          (((sloc <opaque>)
            (stmt
             (SList
              (((sloc <opaque>)
                (stmt
                 (Decl (decl_adtype AutoDiffable) (decl_id j) (decl_type UInt))))
               ((sloc <opaque>) (stmt Skip))))))
           ((sloc <opaque>)
            (stmt
             (Assignment
              ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var j))
               (texpr_adlevel DataOnly))
              ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
               (texpr_adlevel DataOnly)))))))))))
     (params ()) (tparams ()) (prepare_params ())
     (log_prob
      (((sloc <opaque>)
        (stmt
         (SList
          (((sloc <opaque>)
            (stmt (Decl (decl_adtype AutoDiffable) (decl_id j) (decl_type UInt))))
           ((sloc <opaque>) (stmt Skip))))))
       ((sloc <opaque>)
        (stmt
         (For (loopvar x)
          (lower
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
            (texpr_adlevel DataOnly)))
          (upper
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
            (texpr_adlevel DataOnly)))
          (body
           ((sloc <opaque>)
            (stmt
             (Block
              (((sloc <opaque>)
                (stmt
                 (NRFunApp print
                  (((texpr_type UInt) (texpr_loc <opaque>)
                    (texpr
                     (FunApp Plus__
                      (((texpr_type UInt) (texpr_loc <opaque>)
                        (texpr (Lit Int 42)) (texpr_adlevel DataOnly))
                       ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var j))
                        (texpr_adlevel DataOnly)))))
                    (texpr_adlevel DataOnly))))))))))))))))
     (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "constant propagation, model block local scope" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        int i;
        i = 42;
        int j;
        j = 2;
      }
      generated quantities {
        int i;
        int j;
        for (x in 1:i) {
          print(i + j);
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = constant_propagation mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
    ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
     (params ()) (tparams ()) (prepare_params ())
     (log_prob
      (((sloc <opaque>)
        (stmt
         (SList
          (((sloc <opaque>)
            (stmt (Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))))
           ((sloc <opaque>) (stmt Skip))))))
       ((sloc <opaque>)
        (stmt
         (Assignment
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
           (texpr_adlevel DataOnly))
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
           (texpr_adlevel DataOnly)))))
       ((sloc <opaque>)
        (stmt
         (SList
          (((sloc <opaque>)
            (stmt (Decl (decl_adtype AutoDiffable) (decl_id j) (decl_type UInt))))
           ((sloc <opaque>) (stmt Skip))))))
       ((sloc <opaque>)
        (stmt
         (Assignment
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var j))
           (texpr_adlevel DataOnly))
          ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
           (texpr_adlevel DataOnly)))))))
     (gen_quant_vars
      ((i ((tvident i) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))
       (j ((tvident j) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))))
     (generate_quantities
      (((sloc <opaque>)
        (stmt
         (For (loopvar x)
          (lower
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
            (texpr_adlevel DataOnly)))
          (upper
           ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
            (texpr_adlevel DataOnly)))
          (body
           ((sloc <opaque>)
            (stmt
             (Block
              (((sloc <opaque>)
                (stmt
                 (NRFunApp print
                  (((texpr_type UInt) (texpr_loc <opaque>)
                    (texpr
                     (FunApp Plus__
                      (((texpr_type UInt) (texpr_loc <opaque>)
                        (texpr (Lit Int 42)) (texpr_adlevel DataOnly))
                       ((texpr_type UInt) (texpr_loc <opaque>)
                        (texpr (Lit Int 2)) (texpr_adlevel DataOnly)))))
                    (texpr_adlevel DataOnly))))))))))))))))
     (prog_name "") (prog_path "")) |}]

let%expect_test "expression propagation" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      transformed data {
        int i;
        int j;
        j = 2 + i;
      }
      model {
        for (x in 1:i) {
          print(i + j);
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = expression_propagation mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ())
       (tdata_vars
        ((i ((tvident i) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))
         (j ((tvident j) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))))
       (prepare_data
        (((sloc <opaque>)
          (stmt
           (Assignment
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var j))
             (texpr_adlevel DataOnly))
            ((texpr_type UInt) (texpr_loc <opaque>)
             (texpr
              (FunApp Plus__
               (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                 (texpr_adlevel DataOnly))
                ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
                 (texpr_adlevel DataOnly)))))
             (texpr_adlevel DataOnly)))))))
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (For (loopvar x)
            (lower
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
              (texpr_adlevel DataOnly)))
            (upper
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
              (texpr_adlevel DataOnly)))
            (body
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Plus__
                        (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr
                           (FunApp Plus__
                            (((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Lit Int 2)) (texpr_adlevel DataOnly))
                             ((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Var i)) (texpr_adlevel DataOnly)))))
                          (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "copy propagation" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      transformed data {
        int i;
        int j;
        j = i;
        int k;
        k = 2 * j;
      }
      model {
        for (x in 1:i) {
          print(i + j + k);
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = copy_propagation mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ())
       (tdata_vars
        ((i ((tvident i) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))
         (j ((tvident j) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))
         (k ((tvident k) (tvtype SInt) (tvtrans Identity) (tvloc <opaque>)))))
       (prepare_data
        (((sloc <opaque>)
          (stmt
           (Assignment
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var j))
             (texpr_adlevel DataOnly))
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
             (texpr_adlevel DataOnly)))))
         ((sloc <opaque>)
          (stmt
           (Assignment
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var k))
             (texpr_adlevel DataOnly))
            ((texpr_type UInt) (texpr_loc <opaque>)
             (texpr
              (FunApp Times__
               (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                 (texpr_adlevel DataOnly))
                ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
                 (texpr_adlevel DataOnly)))))
             (texpr_adlevel DataOnly)))))))
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (For (loopvar x)
            (lower
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
              (texpr_adlevel DataOnly)))
            (upper
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
              (texpr_adlevel DataOnly)))
            (body
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (NRFunApp print
                    (((texpr_type UInt) (texpr_loc <opaque>)
                      (texpr
                       (FunApp Plus__
                        (((texpr_type UInt) (texpr_loc <opaque>)
                          (texpr
                           (FunApp Plus__
                            (((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Var i)) (texpr_adlevel DataOnly))
                             ((texpr_type UInt) (texpr_loc <opaque>)
                              (texpr (Var i)) (texpr_adlevel DataOnly)))))
                          (texpr_adlevel DataOnly))
                         ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var k))
                          (texpr_adlevel DataOnly)))))
                      (texpr_adlevel DataOnly))))))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "dead code elimination" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      transformed data {
        int i[2];
        i[1] = 2;
        i = {3, 2};
        int j[2];
        j = {3, 2};
        j[1] = 2;
      }
      model {
        print(i);
        print(j);
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = dead_code_elimination mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ())
       (tdata_vars
        ((i
          ((tvident i)
           (tvtype
            (SArray SInt
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
              (texpr_adlevel DataOnly))))
           (tvtrans Identity) (tvloc <opaque>)))
         (j
          ((tvident j)
           (tvtype
            (SArray SInt
             ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
              (texpr_adlevel DataOnly))))
           (tvtrans Identity) (tvloc <opaque>)))))
       (prepare_data
        (((sloc <opaque>)
          (stmt
           (Assignment
            ((texpr_type (UArray UInt)) (texpr_loc <opaque>) (texpr (Var i))
             (texpr_adlevel DataOnly))
            ((texpr_type (UArray UInt)) (texpr_loc <opaque>)
             (texpr
              (FunApp make_array
               (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                 (texpr_adlevel DataOnly))
                ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                 (texpr_adlevel DataOnly)))))
             (texpr_adlevel DataOnly)))))
         ((sloc <opaque>)
          (stmt
           (Assignment
            ((texpr_type (UArray UInt)) (texpr_loc <opaque>) (texpr (Var j))
             (texpr_adlevel DataOnly))
            ((texpr_type (UArray UInt)) (texpr_loc <opaque>)
             (texpr
              (FunApp make_array
               (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                 (texpr_adlevel DataOnly))
                ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
                 (texpr_adlevel DataOnly)))))
             (texpr_adlevel DataOnly)))))
         ((sloc <opaque>)
          (stmt
           (Assignment
            ((texpr_type UInt) (texpr_loc <opaque>)
             (texpr
              (Indexed
               ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var j))
                (texpr_adlevel DataOnly))
               ((Single
                 ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
                  (texpr_adlevel DataOnly))))))
             (texpr_adlevel DataOnly))
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 2))
             (texpr_adlevel DataOnly)))))))
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type (UArray UInt)) (texpr_loc <opaque>) (texpr (Var i))
              (texpr_adlevel DataOnly))))))
         ((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type (UArray UInt)) (texpr_loc <opaque>) (texpr (Var j))
              (texpr_adlevel DataOnly))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "dead code elimination decl" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        int i;
        i = 4;
      }
      generated quantities {
        {
          int i;
          print(i);
        }
      }
      |}
  in
  (* TODO: this doesn't work yet with global variables i. Ask Sean to
     not remove top decls? *)
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = dead_code_elimination mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt (Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))))))))))
       (gen_quant_vars ())
       (generate_quantities
        (((sloc <opaque>)
          (stmt
           (Block
            (((sloc <opaque>)
              (stmt
               (SList
                (((sloc <opaque>)
                  (stmt
                   (Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))))))))
             ((sloc <opaque>)
              (stmt
               (NRFunApp print
                (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
                  (texpr_adlevel DataOnly))))))))))))
       (prog_name "") (prog_path "")) |}]

let%expect_test "dead code elimination functions" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      functions {
        real f() {
          int x;
          x = 23;
          return 24;
        }
      }
      model {
        print(42);
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = dead_code_elimination mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block
        (((sloc <opaque>)
          (stmt
           (FunDef (fdrt (UReal)) (fdname f) (fdargs ())
            (fdbody
             ((sloc <opaque>)
              (stmt
               (Block
                (((sloc <opaque>)
                  (stmt
                   (SList
                    (((sloc <opaque>)
                      (stmt
                       (Decl (decl_adtype AutoDiffable) (decl_id x)
                        (decl_type UInt))))))))
                 ((sloc <opaque>)
                  (stmt
                   (Return
                    (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 24))
                      (texpr_adlevel DataOnly))))))))))))))))
       (data_vars ()) (tdata_vars ()) (prepare_data ()) (params ()) (tparams ())
       (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 42))
              (texpr_adlevel DataOnly))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "dead code elimination, for loop" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        int i;
        print(i);
        for (j in 3:5);
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = dead_code_elimination mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt (Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))))))))
         ((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
              (texpr_adlevel DataOnly))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "dead code elimination, while loop" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        int i;
        print(i);
        while (0) {
          print(13);
        };
        while (1) {
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = dead_code_elimination mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt (Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))))))))
         ((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
              (texpr_adlevel DataOnly))))))
         ((sloc <opaque>)
          (stmt
           (While
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 1))
             (texpr_adlevel DataOnly))
            ((sloc <opaque>) (stmt Skip)))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "dead code elimination, if then" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        int i;
        print(i);
        if (1) {
          print("hello");
        } else {
          print("goodbye");
        }
        if (0) {
          print("hello");
        } else {
          print("goodbye");
        }
        if (i) {

        } else {

        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = dead_code_elimination mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt (Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))))))))
         ((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
              (texpr_adlevel DataOnly))))))
         ((sloc <opaque>)
          (stmt
           (Block
            (((sloc <opaque>)
              (stmt
               (NRFunApp print
                (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str hello))
                  (texpr_adlevel DataOnly))))))))))
         ((sloc <opaque>)
          (stmt
           (Block
            (((sloc <opaque>)
              (stmt
               (NRFunApp print
                (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Lit Str goodbye))
                  (texpr_adlevel DataOnly))))))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "dead code elimination, nested" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        int i;
        print(i);
        for (j in 3:5) {
          for (k in 34:2);
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = dead_code_elimination mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt (Decl (decl_adtype AutoDiffable) (decl_id i) (decl_type UInt))))))))
         ((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
              (texpr_adlevel DataOnly))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "partial evaluation" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        if (1 > 2) {
          int i;
          print(1+2);
          print(i + (1+2));
          print(log(1-i));
        }
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = partial_evaluation mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (IfElse
            ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 0))
             (texpr_adlevel DataOnly))
            ((sloc <opaque>)
             (stmt
              (Block
               (((sloc <opaque>)
                 (stmt
                  (SList
                   (((sloc <opaque>)
                     (stmt
                      (Decl (decl_adtype AutoDiffable) (decl_id i)
                       (decl_type UInt))))
                    ((sloc <opaque>) (stmt Skip))))))
                ((sloc <opaque>)
                 (stmt
                  (NRFunApp print
                   (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                     (texpr_adlevel DataOnly))))))
                ((sloc <opaque>)
                 (stmt
                  (NRFunApp print
                   (((texpr_type UInt) (texpr_loc <opaque>)
                     (texpr
                      (FunApp Plus__
                       (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
                         (texpr_adlevel DataOnly))
                        ((texpr_type UInt) (texpr_loc <opaque>) (texpr (Lit Int 3))
                         (texpr_adlevel DataOnly)))))
                     (texpr_adlevel DataOnly))))))
                ((sloc <opaque>)
                 (stmt
                  (NRFunApp print
                   (((texpr_type UReal) (texpr_loc <opaque>)
                     (texpr
                      (FunApp log1m
                       (((texpr_type UInt) (texpr_loc <opaque>) (texpr (Var i))
                         (texpr_adlevel DataOnly)))))
                     (texpr_adlevel DataOnly))))))))))
            ())))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

let%expect_test "try partially evaluate" =
  let ast =
    Parse.parse_string Parser.Incremental.program
      {|
      model {
        real x;
        real y;
        vector[2] a;
        vector[2] b;
        print(log(exp(x)-exp(y)));
        print(log(exp(a)-exp(b)));
      }
      |}
  in
  let ast = Semantic_check.semantic_check_program ast in
  let mir = Ast_to_Mir.trans_prog "" ast in
  let mir = partial_evaluation mir in
  print_s [%sexp (mir : Mir.typed_prog)] ;
  [%expect
    {|
      ((functions_block ()) (data_vars ()) (tdata_vars ()) (prepare_data ())
       (params ()) (tparams ()) (prepare_params ())
       (log_prob
        (((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id x) (decl_type UReal))))
             ((sloc <opaque>) (stmt Skip))))))
         ((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id y) (decl_type UReal))))
             ((sloc <opaque>) (stmt Skip))))))
         ((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id a) (decl_type UVector))))
             ((sloc <opaque>) (stmt Skip))))))
         ((sloc <opaque>)
          (stmt
           (SList
            (((sloc <opaque>)
              (stmt
               (Decl (decl_adtype AutoDiffable) (decl_id b) (decl_type UVector))))
             ((sloc <opaque>) (stmt Skip))))))
         ((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UReal) (texpr_loc <opaque>)
              (texpr
               (FunApp log_diff_exp
                (((texpr_type UReal) (texpr_loc <opaque>) (texpr (Var x))
                  (texpr_adlevel AutoDiffable))
                 ((texpr_type UReal) (texpr_loc <opaque>) (texpr (Var y))
                  (texpr_adlevel AutoDiffable)))))
              (texpr_adlevel AutoDiffable))))))
         ((sloc <opaque>)
          (stmt
           (NRFunApp print
            (((texpr_type UVector) (texpr_loc <opaque>)
              (texpr
               (FunApp log
                (((texpr_type UVector) (texpr_loc <opaque>)
                  (texpr
                   (FunApp Minus__
                    (((texpr_type UVector) (texpr_loc <opaque>)
                      (texpr
                       (FunApp exp
                        (((texpr_type UVector) (texpr_loc <opaque>) (texpr (Var a))
                          (texpr_adlevel AutoDiffable)))))
                      (texpr_adlevel AutoDiffable))
                     ((texpr_type UVector) (texpr_loc <opaque>)
                      (texpr
                       (FunApp exp
                        (((texpr_type UVector) (texpr_loc <opaque>) (texpr (Var b))
                          (texpr_adlevel AutoDiffable)))))
                      (texpr_adlevel AutoDiffable)))))
                  (texpr_adlevel AutoDiffable)))))
              (texpr_adlevel AutoDiffable))))))))
       (gen_quant_vars ()) (generate_quantities ()) (prog_name "") (prog_path "")) |}]

(* Let's do a simple CSE pass,
ideally expressed as a visitor with a separate visit() function? *)
(*
open Core_kernel
open Mir

let _counter = ref 0;;
let gensym =
  fun () ->
    _counter := (!_counter) + 1;
    String.concat ["sym"; (string_of_int !_counter)];;

let rec count_subtrees_rec fnapp2sym e =
  match e with
  | FnApp(_, args) ->
    let _ = List.map args ~f:(count_subtrees_rec fnapp2sym) in
    Hashtbl.Poly.update fnapp2sym e ~f:(function Some(i) -> i+1 | None -> 1)
  | _ -> ()

let count_subtrees e = let fnapp2sym = Hashtbl.Poly.create () in
  count_subtrees_rec fnapp2sym e;
  fnapp2sym

let%expect_test "count_subtrees" =
  let dict = count_subtrees (FnApp("plus",
                                   [FnApp("plus", [Lit(Int, "2"); Lit(Int, "3")]);
                                    FnApp("plus", [Lit(Int, "2"); Lit(Int, "3")])])) in
  print_s [%sexp (Hashtbl.Poly.to_alist dict : (expr * int) list)];
  [%expect{|
    (((FnApp plus ((Lit Int 2) (Lit Int 3))) 2)
     ((FnApp plus
       ((FnApp plus ((Lit Int 2) (Lit Int 3)))
        (FnApp plus ((Lit Int 2) (Lit Int 3)))))
      1)) |}]

let filter_dups fnapp2sym =
  let dups = Hashtbl.Poly.filter fnapp2sym ~f:(fun x -> x > 1) in
  Hashtbl.Poly.map dups ~f:(fun _ -> gensym ())

let add_assigns dups e =
  if Hashtbl.Poly.is_empty dups then e
  else
    Hashtbl.Poly.fold dups ~init:[e] ~f:(fun ~key:ast_node ~data:var l ->
        AssignExpr(var, ast_node) :: l)
    |> ExprList

let%expect_test "add_assigns" =
  let ast_node = (FnApp("plus", [Lit(Int, "2")])) in
  let dups = Hashtbl.Poly.of_alist_exn [(Var "hi"), "lo"] in
  print_s [%sexp ((add_assigns dups ast_node) : expr)];
  [%expect{| (ExprList ((AssignExpr lo (Var hi)) (FnApp plus ((Lit Int 2))))) |}]

let rec replace_usages dups e = match Hashtbl.Poly.find dups e with
  | Some(sym) -> Var sym
  | None -> (match e with
      | FnApp(fname, args) -> FnApp(fname, List.map args
                                      ~f:(replace_usages dups))
      | x -> x)

let%expect_test "replace_usages" =
  let e = (FnApp("p", [Lit(Int, "2")])) in
  let dups = Hashtbl.Poly.of_alist_exn [e, "sup"] in
  print_s [%sexp ((replace_usages dups e) : expr)];
  [%expect{| (Var sup) |}]

let cse e = let dups = filter_dups (count_subtrees e) in
  add_assigns dups (replace_usages dups e)

let optimize e =
  e |> Peep.run_peephole_opts |> cse

let%expect_test _ =
  print_s [%sexp
    ((optimize
        (FnApp("plus",
               [FnApp("log", [FnApp("minus", [Lit(Int, "1"); (Var "hi")])]);
                FnApp("log", [FnApp("minus", [Lit(Int, "1"); (Var "hi")])])])))
     : expr)];
  [%expect{|
      (ExprList
       ((AssignExpr sym1 (FnApp log1m ((Var hi))))
        (FnApp plus ((Var sym1) (Var sym1))))) |}]
*)

(* XXX
   Todos to make code gen as good as Stan 2 codegen
   1. Turn all autodiff types on vardecls in data block to data type
   2. CSE
   3. loop-invariant code motion
*)
