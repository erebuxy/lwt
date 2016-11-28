(* Lightweight thread library for OCaml
 * http://www.ocsigen.org/lwt
 * Copyright (C) 2016 Anton Bachin
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, with linking exceptions;
 * either version 2.1 of the License, or (at your option) any later
 * version. See COPYING file for details.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 * 02111-1307, USA.
 *)

open Test
open Lwt.Infix

let utimes_tests = [
  test "utimes: basic"
    (fun () ->
      let temporary_file = temp_file () in

      Lwt_unix.utimes temporary_file 1. 2. >>= fun () ->
      let stat = Unix.stat temporary_file in
      let c1 = stat.Unix.st_atime = 1. in
      let c2 = stat.Unix.st_mtime = 2. in

      Lwt.return (c1 && c2));

  test "utimes: current time"
    (fun () ->
      (* Unix.stat reports times about an hour away from those set by
         Unix.utimes on Windows on MinGW. Have not searched for the root cause
         yet. *)
      let acceptable_delta = if Sys.win32 then 7200. else 2. in
      let now = Unix.gettimeofday () in

      let temporary_file = temp_file () in

      Lwt_unix.utimes temporary_file 1. 2. >>= fun () ->
      Lwt_unix.utimes temporary_file 0. 0. >>= fun () ->
      let stat = Unix.stat temporary_file in
      let c1 = abs_float (stat.Unix.st_atime -. now) < acceptable_delta in
      let c2 = abs_float (stat.Unix.st_mtime -. now) < acceptable_delta in

      Lwt.return (c1 && c2));

  test "utimes: missing file"
    (fun () ->
      Lwt.catch
        (fun () -> Lwt_unix.utimes "non-existent-file" 0. 0.)
        (function
        | Unix.Unix_error (Unix.ENOENT, "utimes", _) -> Lwt.return_unit
        | e -> Lwt.fail e) [@ocaml.warning "-4"] >>= fun () ->
      Lwt.return_true);
]

let readdir_tests =
  let populate n =
    let path = temp_directory () in

    let filenames =
      let rec loop n acc =
        if n <= 0 then acc
        else loop (n - 1) ((string_of_int n)::acc)
      in
      loop n []
    in

    List.iter (fun filename ->
      let fd =
        Unix.(openfile
          (Filename.concat path filename) [O_WRONLY; O_CREAT] 0o644)
      in
      Unix.close fd)
      filenames;

    path, ["."; ".."] @ filenames
  in

  let equal, subset =
    let module StringSet = Set.Make (String) in
    (* Necessary before 4.02. *)
    let of_list l =
      List.fold_left (fun set n -> StringSet.add n set) StringSet.empty l in

    (fun filenames filenames' ->
      StringSet.equal (of_list filenames) (of_list filenames')),

    (fun filenames filenames' ->
      StringSet.subset (of_list filenames) (of_list filenames'))
  in

  let read_all directory =
    let rec loop acc =
      Lwt.catch
        (fun () ->
          Lwt_unix.readdir directory >>= fun filename ->
          Lwt.return (Some filename))
        (function
          | End_of_file -> Lwt.return_none
          | exn -> Lwt.fail exn)
      >>= function
        | None -> Lwt.return acc
        | Some filename -> loop (filename::acc)
    in
    loop []
  in

  let read_n directory n =
    let rec loop n acc =
      if n <= 0 then Lwt.return acc
      else
        Lwt_unix.readdir directory >>= fun filename ->
        loop (n - 1) (filename::acc)
    in
    loop n []
  in

  [
    test "readdir: basic"
      (fun () ->
        let path, filenames = populate 5 in

        Lwt_unix.opendir path >>= fun directory ->
        read_all directory >>= fun filenames' ->
        Lwt_unix.closedir directory >>= fun () ->

        Lwt.return (List.length filenames' = 7 && equal filenames filenames'));

    test "readdir: rewinddir"
      (fun () ->
        let path, filenames = populate 5 in

        Lwt_unix.opendir path >>= fun directory ->
        read_n directory 3 >>= fun filenames' ->
        Lwt_unix.rewinddir directory >>= fun () ->
        read_all directory >>= fun filenames'' ->
        Lwt_unix.closedir directory >>= fun () ->

        Lwt.return
          (List.length filenames' = 3 &&
           subset filenames' filenames &&
           List.length filenames'' = 7 &&
           equal filenames'' filenames));

    test "readdir: readdir_n"
      (fun () ->
        let path, filenames = populate 5 in

        Lwt_unix.opendir path >>= fun directory ->
        Lwt_unix.readdir_n directory 3 >>= fun filenames' ->
        Lwt_unix.readdir_n directory 10 >>= fun filenames'' ->
        Lwt_unix.closedir directory >>= fun () ->

        let all = (Array.to_list filenames') @ (Array.to_list filenames'') in

        Lwt.return
          (Array.length filenames' = 3 &&
           Array.length filenames'' = 4 &&
           equal all filenames));

    test "readdir: files_of_directory"
      (fun () ->
        let path, filenames = populate 5 in

        let stream = Lwt_unix.files_of_directory path in
        Lwt_stream.to_list stream >>= fun filenames' ->

        Lwt.return (equal filenames' filenames));

    (* Should make sure Win32 behaves in the same way as well. *)
    test "readdir: already closed" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let path, _ = populate 0 in

        Lwt_unix.opendir path >>= fun directory ->
        Lwt_unix.closedir directory >>= fun () ->

        let expect_ebadf tag t =
          let tag = "Lwt_unix." ^ tag in
          Lwt.catch
            (fun () ->
              t () >>= fun () ->
              Lwt.return_false)
            (function
              | Unix.Unix_error (Unix.EBADF, tag', _) when tag' = tag ->
                Lwt.return_true
              | exn -> Lwt.fail exn) [@ocaml.warning "-4"]
        in

        Lwt_list.for_all_s (fun (tag, t) -> expect_ebadf tag t)
          ["readdir", (fun () -> Lwt_unix.readdir directory >|= ignore);
           "readdir_n", (fun () -> Lwt_unix.readdir_n directory 1 >|= ignore);
           "rewinddir", (fun () -> Lwt_unix.rewinddir directory);
           "closedir", (fun () -> Lwt_unix.closedir directory)]);
  ]

let writev_tests =
  let make_io_vectors vecs =
    let open Lwt_unix.IO_vectors in
    let io_vectors = create () in
    List.iter (function
      | `Bytes (s, offset, length) ->
        append_bytes io_vectors (Bytes.unsafe_of_string s) offset length
      | `Bigarray (s, offset, length) ->
        append_bigarray io_vectors (Lwt_bytes.of_string s) offset length)
      vecs;
    io_vectors
  in

  let writer ?blocking write_fd io_vectors data_length = fun () ->
    Lwt_unix.blocking write_fd >>= fun is_blocking ->
    Gc.full_major ();
    Lwt_unix.writev write_fd io_vectors >>= fun bytes_written ->
    Lwt_unix.close write_fd >>= fun () ->
    let blocking_matches =
      match blocking, is_blocking with
      | Some v, v' when v <> v' -> false
      | _ -> true
    in
    Lwt.return (bytes_written = data_length && blocking_matches)
  in

  let reader read_fd ?(not_readable = false) expected_data = fun () ->
    if not_readable then
      let readable = Lwt_unix.readable read_fd in
      Lwt_unix.close read_fd >>= fun () ->
      Lwt.return (not readable)
    else
      let open! Lwt_io in
      let channel = of_fd ~mode:input read_fd in
      read channel >>= fun read_data ->
      close channel >>= fun () ->
      Lwt.return (read_data = expected_data)
  in

  [
    test "writev: basic non-blocking" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let io_vectors =
          make_io_vectors
            [`Bytes ("foo", 0, 3);
             `Bytes ("bar", 0, 3);
             `Bigarray ("baz", 0, 3)]
        in

        let read_fd, write_fd = Lwt_unix.pipe () in

        Lwt_list.for_all_s (fun t -> t ())
          [writer ~blocking:false write_fd io_vectors 9;
           reader read_fd "foobarbaz"]);

    test "writev: basic blocking" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let io_vectors =
          make_io_vectors
            [`Bytes ("foo", 0, 3);
             `Bytes ("bar", 0, 3);
             `Bigarray ("baz", 0, 3)]
        in

        let read_fd, write_fd = Lwt_unix.pipe () in
        Lwt_unix.set_blocking write_fd true;

        Lwt_list.for_all_s (fun t -> t ())
          [writer ~blocking:true write_fd io_vectors 9;
           reader read_fd "foobarbaz"]);

    test "writev: slices" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let io_vectors =
          make_io_vectors [`Bytes ("foo", 1, 2); `Bigarray ("bar", 1, 2)] in

        let read_fd, write_fd = Lwt_unix.pipe () in

        Lwt_list.for_all_s (fun t -> t ())
          [writer write_fd io_vectors 4;
           reader read_fd "ooar"]);

    test "writev: drop, is_empty" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let io_vectors =
          make_io_vectors
            [`Bytes ("foo", 0, 3);
             `Bytes ("bar", 0, 3);
             `Bigarray ("baz", 0, 3)]
        in

        let read_fd, write_fd = Lwt_unix.pipe () in

        let initially_empty = Lwt_unix.IO_vectors.is_empty io_vectors in

        Lwt_unix.IO_vectors.drop io_vectors 4;
        let empty_after_partial_drop =
          Lwt_unix.IO_vectors.is_empty io_vectors in

        Lwt_list.for_all_s (fun t -> t ())
          [writer write_fd io_vectors 5;
           reader read_fd "arbaz"] >>= fun io_correct ->

        Lwt_unix.IO_vectors.drop io_vectors 5;
        let empty_after_exact_drop = Lwt_unix.IO_vectors.is_empty io_vectors in

        Lwt_unix.IO_vectors.drop io_vectors 100;
        let empty_after_excess_drop = Lwt_unix.IO_vectors.is_empty io_vectors in

        Lwt.return
          (not initially_empty &&
           not empty_after_partial_drop &&
           io_correct &&
           empty_after_exact_drop &&
           empty_after_excess_drop));

    test "writev: degenerate vectors" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let io_vectors =
          make_io_vectors
            [`Bytes ("foo", 0, 0);
             `Bigarray ("bar", 0, 0)]
        in

        let read_fd, write_fd = Lwt_unix.pipe () in

        let initially_empty = Lwt_unix.IO_vectors.is_empty io_vectors in

        Lwt_list.for_all_s (fun t -> t ())
          [writer write_fd io_vectors 0;
           reader read_fd ""] >>= fun io_correct ->

        Lwt.return (initially_empty && io_correct));

    test "writev: bad iovec" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let negative_offset = make_io_vectors [`Bytes ("foo", -1, 3)] in
        let negative_length = make_io_vectors [`Bytes ("foo", 0, -1)] in
        let out_of_bounds = make_io_vectors [`Bytes ("foo", 1, 3)] in

        let negative_offset' = make_io_vectors [`Bigarray ("foo", -1, 3)] in
        let negative_length' = make_io_vectors [`Bigarray ("foo", 0, -1)] in
        let out_of_bounds' = make_io_vectors [`Bigarray ("foo", 1, 3)] in

        let read_fd, write_fd = Lwt_unix.pipe () in

        let writer io_vectors =
          fun () ->
            Lwt.catch
              (fun () ->
                Lwt_unix.writev write_fd io_vectors >>= fun _ ->
                Lwt.return_false)
              (function
                | Invalid_argument _ -> Lwt.return_true
                | e -> Lwt.fail e)
        in

        let close write_fd = fun () ->
          Lwt_unix.close write_fd >>= fun () -> Lwt.return_true in

        Lwt_list.for_all_s (fun t -> t ())
          [writer negative_offset;
           writer negative_length;
           writer out_of_bounds;
           writer negative_offset';
           writer negative_length';
           writer out_of_bounds';
           reader read_fd ~not_readable:true "";
           close write_fd]);

    test "writev: iovecs exceeding limit"
      ~only_if:(fun () -> not Sys.win32 &&
                          Lwt_unix.IO_vectors.system_limit <> None)
      (fun () ->
        let limit =
          match Lwt_unix.IO_vectors.system_limit with
          | Some limit -> limit
          | None -> assert false
        in

        let io_vectors =
          let open Lwt_unix.IO_vectors in
          let io_vectors = create () in
          let rec loop count =
            if count < 1 then io_vectors
            else
              (append_bytes io_vectors (Bytes.unsafe_of_string "a") 0 1;
              loop (count - 1))
          in
          loop (limit + 1)
        in

        let read_fd, write_fd = Lwt_unix.pipe () in

        Lwt_list.for_all_s (fun t -> t ())
          [writer write_fd io_vectors limit;
           reader read_fd (String.make limit 'a')]);

    test "writev: negative drop" ~only_if:(fun () -> not Sys.win32)
      (fun () ->
        let io_vectors = make_io_vectors [`Bytes ("foo", 0, 3)] in
        Lwt_unix.IO_vectors.drop io_vectors (-1);

        let read_fd, write_fd = Lwt_unix.pipe () in

        Lwt_list.for_all_s (fun t -> t ())
          [writer write_fd io_vectors 3;
           reader read_fd "foo"] >>= fun io_correct ->

        Lwt.return
          (io_correct &&
           not (Lwt_unix.IO_vectors.is_empty io_vectors)));
  ]

let bind_tests = [
  test "bind: basic"
    (fun () ->
      let address = Unix.(ADDR_INET (inet_addr_loopback, 56100)) in
      let socket = Lwt_unix.(socket PF_INET SOCK_STREAM 0) in

      Lwt.finalize
        (fun () ->
          Lwt_unix.Versioned.bind_2 socket address >>= fun () ->
          Lwt.return (Unix.getsockname (Lwt_unix.unix_file_descr socket)))
        (fun () ->
          Lwt_unix.close socket)

      >>= fun address' ->

      Lwt.return (address' = address));

  test "bind: Unix domain" ~only_if:(fun () -> not Sys.win32)
    (fun () ->
      let socket = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in

      let rec bind_loop attempts =
        if attempts <= 0 then
          Lwt.fail (Unix.Unix_error (Unix.EADDRINUSE, "bind", ""))
        else
          let path = temp_name () in
          let address = Unix.(ADDR_UNIX path) in
          Lwt.catch
            (fun () ->
              Lwt_unix.Versioned.bind_2 socket address >>= fun () ->
              Lwt.return_true)
            (function
              | Unix.Unix_error (Unix.EADDRINUSE, "bind", _) -> Lwt.return_false
              | e -> Lwt.fail e) [@ocaml.warning "-4"] >>= fun bound ->
          if bound then
            Lwt.return path
          else
            bind_loop (attempts - 1)
      in

      Lwt.finalize
        (fun () ->
          bind_loop 5 >>= fun chosen_path ->
          let actual_path =
            Unix.getsockname (Lwt_unix.unix_file_descr socket) in
          Lwt.return (chosen_path, actual_path))
        (fun () ->
          Lwt_unix.close socket)
      >>= fun (chosen_path, actual_path) ->

      let actual_path =
        match actual_path with
        | Unix.ADDR_UNIX path -> path
        | Unix.ADDR_INET _ -> assert false
      in

      (try Unix.unlink chosen_path
      with _ -> ());
      (try Unix.unlink actual_path
      with _ -> ());

      Lwt.return (chosen_path = actual_path));
]

let suite =
  suite "lwt_unix"
    (utimes_tests @
     readdir_tests @
     writev_tests @
     bind_tests)