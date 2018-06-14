---
layout: post
title: Writing a JIT Brainfuck interpreter with LLVM and OCaml
toc: true
---

## Introduction

Welcome to my Brainfuck interpreter tutorial! In this post I will go over how I created
[my own LLVM based Brainfuck interpreter](https://github.com/lukad/obf) with OCaml.

## Rationale

I'll briefly explain my choice of tools here.

### Why Brainfuck

Although brainfuck is an [esoteric programming language](https://en.wikipedia.org/wiki/Esoteric_programming_language) without any serious real world use cases, it is easy enough to understand but at the same time challenging enough to implement to serve as a coding exercise when learning a new language or a new framework. Of course it's still possible to write really complex in Brainfuck. Take this fibonacci
generator for example `>-[[<+>>>-<-<+]>]` or this [mandelbrot viewer](http://esoteric.sange.fi/brainfuck/utils/mandelbrot/) or this [game of life implementation](http://www.linusakesson.net/programming/brainfuck/).

### Why OCaml

When I first tried to learn LLVM I went through the official [Kaleidoscope tutorial](https://llvm.org/docs/tutorial/) using C++. I found it extremely frustrating because it was pretty outdated and I wanted to use the current LLVM version. The OCaml version of that tutorial wasn't any better but I liked OCaml's LLVM bindings and their [documentation](https://llvm.moe/ocaml/) a lot more.

OCaml is even being used in the real world by some pretty big players.
To name a few interesting projects:

* [Hack (Facebook)](https://github.com/facebook/hhvm/tree/master/hphp/hack) A language targeting the HHVM
* [ReasonML (Facebook)](https://reasonml.github.io/): An alternative OCaml syntax
* [BuckleScript (Bloomberg)](https://bucklescript.github.io/): OCaml to JS compiler
* [MirageOS](https://mirage.io/): Library for building [unikernels](https://en.wikipedia.org/wiki/Unikernel)
* [Unison](https://www.cis.upenn.edu/~bcpierce/unison/): File synchronization tool
* [Emscripten](http://kripken.github.io/emscripten-site/): An LLVM-to-JavaScript Compiler

### Why LLVM

`TODO`

## AST & Parsing

Before we can start generating any LLVM code we need to be able to parse Brainfuck into
a suitable data structure.

### The Abstract Syntax Tree

An abstract syntax tree is a tree representation of some source code.
This is very simple to model for brainfuck since we don't have any expressions, operators, etc.,
it's just a sequence of instructions. Except for the loop (`[]`), which is itself a sequence of
instructions.

So let's define an enum for our instructions and a type to repreresent the instruction sequence.

``` ocaml
(* ast.ml *)
type program = instruction list

and instruction =
  | Move of int
  | Add of int
  | Loop of program
  | Read
  | Write
  ;;
```

Note that `Move` and `Add` are of `int`. This allows us to combine coesecutive `+`/`-` and `>`/`<` into one instruction.

With this AST definition the following brainfuck code

```
++++ [> ++++ [> ++++ < -] < -] >> .
```

can be represented in OCaml as

``` ocaml
[(Add 4);
 (Loop
   [(Move 1); (Add 4);
    (Loop
      [(Move 1); (Add 4); (Move -1); (Add -1)]);
    (Move -1); (Add -1)]);
  (Move 2); Write]
```

### The Parser

Parsing brainfuck is pretty straightforward except for the loop which needs to be parsed recursively.
I used Angstrom, a parser combinator inspired by the amazing [Parsec](https://wiki.haskell.org/Parsec) library for Haskell.

Since explaining parser combinators is out of scope for this blog post, I'm just going to dump my parser code here with a few comments.

``` ocaml
(* reader.ml *)
(* I used reader instead of parser because parser is a reserved keyword of the Camlp4 extension *)
open Angstrom
open Ast

(* Parse all characters that are not part of Brainfucks instruction set *)
let is_comment c = not (List.mem c ['+'; '-'; '>'; '<'; ','; '.'; '['; ']'])
let comment = many (satisfy is_comment)

(* Parse at least one `char c` and pass it's result to `f` *)
let chars c f = many1 (char c) >>= f

(* Use the chars parser defined above and return `Add`/`Move` with the length of the result *)
let plus = chars '+' (fun s -> return (Add (List.length s)))
let minus = chars '-' (fun s -> return (Add ~-(List.length s)))
let left = chars '>' (fun s -> return (Move (List.length s)))
let right = chars '<' (fun s -> return (Move ~-(List.length s)))

(* Consume a single character and return `Read`/`Write` *)
let read = char ',' *> return Read
let write = char '.' *> return Write

(* Parse one of the simple instructions which may be followed by a comment *)
let simple = (plus <|> minus <|> left <|> right <|> read <|> write) <* comment

(* Parse parser `p` surrounded by square brackets and optionally followed by a comment
 * and return the result of `p` as a `Loop`
 *)
let loop p = (char '[' *> p <* char ']') <* comment
                   >>= fun body -> return (Loop body)

(* Define a parser which parses a sequence of either `simple` or `loop program` *)
let program = fix (fun program -> comment *> many (simple <|> loop program)) <* end_of_input

(* This is the main function to be used to parse a string of Brainfuck source code *)
let read_string = parse_string program
```

``` ocaml
"++++ [> ++++ [> ++++ < -] < -] >> ." |> Reader.read_string |> print_endline
(*
 *
 *
 *
 *)
```

## Basic Optimization

Now that we can parse Brainfuck into our AST it's time to apply some simple optimizations.
We will recursively walk our AST and check if the current instruction can be combined with the next instruction.

We will repeat this step until the AST does not change anymore.

``` ocaml
(* optimizer.ml *)
open Ast

let rec opt = function
  (* Empty lists stay empty *)
  | [] -> []

  (* Eliminate Add/Move instructions with value 0 *)
  | Add 0  :: rest -> opt rest
  | Move 0 :: rest -> opt rest

  (* Combine consecutive Add/Move instructions by summing their values *)
  | Add a  :: Add b  :: rest -> Add (a + b) :: opt rest
  | Move a :: Move b :: rest -> Move (a + b) :: opt rest

  (* Eliminate empty loops *)
  | Loop []         :: rest ->                    opt rest
  (* Optimize the loop body *)
  | Loop body       :: rest -> Loop (opt body) :: opt rest

  (* Otherwise do nothing to the current instruction *)
  | ins :: rest -> ins :: (opt rest)

(* Optimize the program until it stops changing *)
let optimize prog =
  let rec optimize a b =
    if a = b then
      a
    else
      optimize b (opt b)
  in
  optimize prog (opt prog)
```
