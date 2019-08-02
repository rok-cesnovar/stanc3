module Location : module type of Location
module Location_span : module type of Location_span
module Label : module type of Label
module Operator : module type of Operator
module Fun_kind : module type of Fun_kind
module Internal_fun : module type of Internal_fun
module Expr : module type of Expr
module UnsizedType : module type of UnsizedType
module SizedType : module type of SizedType
module Type : module type of Type
module Stmt : module type of Stmt
module Program : module type of Program
module Stan_math : module type of Stan_math
module Utils : module type of Utils

(* val string_of_location :
  ?print_file:bool -> ?print_line:bool -> location -> string *)

(* val string_of_location_span : Mir_pattern.location_span -> string *)
(* val operator_of_string : string -> Mir_pattern.operator option
val string_of_operator : Mir_pattern.operator -> string
val string_of_internal_fn : Mir_pattern.internal_fn -> string
val internal_fn_of_string : string -> Mir_pattern.internal_fn option *)

(* val internal_funapp :
  Mir_pattern.internal_fn -> 'a Mir_pattern.with_expr list -> 'a -> 'a Mir.with_expr *)

(* val no_loc : Mir.location
val no_span : Mir.location_span
val merge_spans : Mir.location_span -> Mir.location_span -> Mir.location_span
val internal_meta : Mir.mtype_loc_ad
val loop_bottom : Mir.mtype_loc_ad Mir.with_expr
val remove_size : 'a Mir.sizedtype -> Mir.unsizedtype
val zero : Mir.mtype_loc_ad Mir.with_expr
val remove_possible_size : 'a possiblysizedtype -> unsizedtype
val sexp_of_expr_typed_located : 'a Mir.with_expr -> Sexp.t
val sexp_of_stmt_loc : ('a, 'b) Mir.stmt_with -> Sexp.t *)
(* val gensym : unit -> string
val gensym_enter : unit -> string * (unit -> unit)
val gensym_reset_danger_use_cautiously : unit -> unit *)

(* val check_compatible_arguments_mod_conv :
     string
  -> (Mir.autodifftype * Mir.unsizedtype) list
  -> (Mir.autodifftype * Mir.unsizedtype) list
  -> bool *)
(** Check that the rhs list of function argument types can be converted to the
    lhs *)
(* val check_of_same_type_mod_array_conv :
  string -> Mir.unsizedtype -> Mir.unsizedtype -> bool
(** Check that the rhs type can be converted to the lhs, where we allow
    conversion inside an array constructor *)

val stan_math_returntype :
  string -> (Mir.autodifftype * Mir.unsizedtype) list -> Mir.returntype option
(** Get an optional return type for a Stan Math library function, given its name and argument types. *)

val assignmentoperator_stan_math_return_type :
     Mir.operator
  -> (Mir.autodifftype * Mir.unsizedtype) list
  -> Mir.returntype option

val operator_stan_math_return_type :
     Mir.operator
  -> (Mir.autodifftype * Mir.unsizedtype) list
  -> Mir.returntype option

val pretty_print_math_lib_operator_sigs : Mir.operator -> string list

val pretty_print_math_lib_assignmentoperator_sigs :
  Mir.operator -> string option

val pretty_print_all_math_lib_fn_sigs : string -> string

val is_stan_math_function_name : string -> bool
(** Check whether a string is the name of a Stan Math library function. *)

val stan_distribution_name_suffix : string -> string

val operator_return_type_from_string :
  string -> (autodifftype * unsizedtype) sexp_list -> returntype option

val operator_return_type :
  operator -> (autodifftype * unsizedtype) sexp_list -> returntype option

val string_of_operators : (string, string sexp_list) Map.Poly.t
val ternary_if : string
val expr_from_idx : expr_typed_located index -> expr_typed_located sexp_list

val binop :
     mtype_loc_ad with_expr
  -> operator
  -> mtype_loc_ad with_expr
  -> mtype_loc_ad with_expr

val contains_fn : string -> ('a, 'b) stmt_with -> bool
val mir_int : int -> mtype_loc_ad with_expr

val mock_for :
     int
  -> (mtype_loc_ad, location_span) stmt_with
  -> (mtype_loc_ad, location_span) stmt_with *)
