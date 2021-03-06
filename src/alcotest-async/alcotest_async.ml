open Core
open Async_kernel
open Async_unix

module Tester = Alcotest.Core.Make (struct
  include Deferred

  let bind x f = bind x ~f
end)

include Tester

let test_case_sync n s f = test_case n s (fun x -> Deferred.return (f x))

let run_test timeout name fn args =
  Clock.with_timeout timeout (fn args) >>| function
  | `Result x -> x
  | `Timeout ->
      Alcotest.fail
        (Printf.sprintf "%s timed out after %s" name
           (Time.Span.to_string_hum timeout))

let test_case ?(timeout = sec 2.) name s f =
  test_case name s (run_test timeout name f)
