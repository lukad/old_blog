---
layout: post
title: Writing a JIT Brainfuck interpreter with LLVM
toc: true
---

## What is Brainfuck?

If you don't know what Brainfuck is, read the [Wikipedia article on Brainfuck](https://en.wikipedia.org/wiki/Brainfuck) and continue reading here.

## AST & Parsing

Before we can start generating any LLVM code we need to be able to parse Brainfuck into
a suitable data structure.

### The Abstract Syntax Tree

An abstract syntax tree is a tree representation of some source code.
This is very simple to model for brainfuck since we don't have any expressions, operators, etc., it's just a sequence of instructions. Except for the loop (`[]`) which is itself a sequence of instructions.

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

Note that `Move` and `Add` are of `int`. This allows us to combine conesecutive `+`/`-` and `>`/`<` into one instruction.

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

Parsing brainfuck is pretty straightforward except for the loop which needs to be parsed recursively.
I used Angstrom, a parser combinator inspired by the amazing Parsec library for [Haskell](https://wiki.haskell.org/Parsec).

Since explaining parser combinators is out of scope for this blog post and because you can easily get away with parsing by hand, I'm just going to dump my parser code here with a few comments.

``` ocaml
(* reader.ml *)
(* I used reader instead of parser because reader is a keyword of the Camlp4 extension *)
open Angstrom

(* Parse all characters that are not part of Brainfucks instruction set *)
let is_comment c = not (List.mem c ['+'; '-'; '>'; '<'; ','; '.'; '['; ']'])
let comment = many (satisfy is_comment)

(* Parse at least one `char c` and pass it's result to `f` *)
let chars c f = many1 (char c) >>= f

(* Use the chars parser defined above and return `Add`/`Move` with the length of the result *)
let plus = chars '+' (fun s -> return (Ast.Add (List.length s)))
let minus = chars '-' (fun s -> return (Ast.Add ~-(List.length s)))
let left = chars '>' (fun s -> return (Ast.Move (List.length s)))
let right = chars '<' (fun s -> return (Ast.Move ~-(List.length s)))

(* Consume a single character and return `Read`/`Write` *)
let read = char ',' *> return Ast.Read
let write = char '.' *> return Ast.Write

(* Parse one of the simple instructions which may be followed by a comment *)
let simple = (plus <|> minus <|> left <|> right <|> read <|> write) <* comment

(* Parse parser `p` surrounded by square brackets and optionally followed by a comment
 * and return the result of `p` as a `Loop`
 *)
let loop p = (char '[' *> p <* char ']') <* comment
                   >>= fun body -> return (Ast.Loop body)

(* Define a parser which parses a sequence of either `simple` or `loop program` *)
let program = fix (fun program -> comment *> many (simple <|> loop program)) <* end_of_input

(* This is the main function to be used to parse a string of Brainfuck source code *)
let read_string = parse_string program
```