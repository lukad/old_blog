---
layout: post
title: Writing a Brainfuck interpreter in Rust
toc: true
---

Welcome to my Brainfuck interpreter tutorial! We will create our own Brainfuck interpreter in Rust and explore some optimization strategies.

## Brainfuck

Although Brainfuck is a so called [esoteric programming language](https://en.wikipedia.org/wiki/Esoteric_programming_language) without any serious real world use cases, it is easy enough to understand but at the same time challenging enough to implement and serve as a coding exercise when learning a new language.

Of course it's still possible to write really complex in Brainfuck programs. Take this fibonacci generator for example `>-[[<+>>>-<-<+]>]` or this [mandelbrot viewer](http://esoteric.sange.fi/brainfuck/utils/mandelbrot/) or this [game of life implementation](http://www.linusakesson.net/programming/brainfuck/).

## Implementation

Our program will be fairly simple. We will parse the Brainfuck code, apply optimizations and then execute it.

Let's start with creating a new rust project.

```
$ cargo new --bin brainfuck
```

### The Abstract Syntax Tree

Parsing the Brainfuck code allows us to represent it in a form other than a string. It can be a list, or rather a tree, of known Instructions. This is called an abstract syntax tree or AST. Using an AST will make our life easier when implementing optimization and execution.


```rust
// ast.rs

/// A list of Instructions that can be executed
pub type Program = Vec<Instruction>;

#[derive(Clone, Debug, PartialEq)]
pub enum Instruction {
    // +
    /// Add `1` to the current cell
    Add,
    // -
    /// Subtract `1` from the current cell
    Sub,
    // >
    /// Move the pointer one cell to the right
    Right,
    // >
    /// Move the pointer one cell to the left
    Left,
    // ,
    /// Read one byte from STDIN and store it in the current cell
    Read,
    // .
    /// Write the byte from the current cell to STDOUT
    Write,
    // []
    /// Repeat the loop body while the current cell is not `0`
    Loop(Program),
}
```

### The Parser

Our parser will be a function that takes an `input` `Read` over which it iterates. All possible Brainfuck instructions will be mapped  to variants of our `Instruction` type and returned as a `Program`.

```rust
// parser.rs

use std::io::Read;

use crate::ast::{Instruction::*, Program};

pub fn parse<R: Read>(input: R) -> Result<Program, &'static str> {
    // We will push all Brainfuck instructions onto this stack
    // where the first element will be our main program.
    // All loops will be temporarily stored on the stack as separate programs.
    let mut stack: Vec<Program> = vec![vec![]];

    for c in input.bytes() {
        match c {
            // The simple instructions can be appended directly
            Ok(b'+') => stack.last_mut().unwrap().push(Add),
            Ok(b'-') => stack.last_mut().unwrap().push(Sub),
            Ok(b'>') => stack.last_mut().unwrap().push(Right),
            Ok(b'<') => stack.last_mut().unwrap().push(Left),
            Ok(b',') => stack.last_mut().unwrap().push(Read),
            Ok(b'.') => stack.last_mut().unwrap().push(Write),

            // Push a new vector onto the stack for the loop body
            Ok(b'[') => {
                stack.push(vec![]);
            }

            // Pop the loop body off the stack and append
            // them to the current program as a loop
            Ok(b']') => {
                // If the stack is smaller than 2 items we are not inside a loop
                if stack.len() < 2 {
                    return Err("Unmatched ]");
                }
                let loop_ins = Loop(stack.pop().unwrap());
                stack.last_mut().unwrap().push(loop_ins);
            }
            // Everything else can be ignored
            _ => (),
        }
    }

    // If there is more than one item on the stack
    // the last loop was not closed
    if stack.len() != 1 {
        return Err("Unmatched [");
    }

    Ok(stack.pop().unwrap())
}
```

Let's hook it up in our `main.rs` and try it out.

```rust
// main.rs

use std::env;
use std::fs::File;

mod parser;

use parser::parse;

fn main() {
    let source = match env::args().nth(1) {
        Some(path) => File::open(path).expect("Could not read source"),
        _ => panic!("No input"),
    };

    let program = parse(source).unwrap();
    println!("{:?}", program);
}
```

Use any program you like to test our interpreter. The following is a well commented "Hello World" I took from wikipedia.

```
$ cat <<EOF> hello.bf
+++++ +++++             initialize counter (cell #0) to 10
[                       use loop to set the next four cells to 70/100/30/10
    > +++++ ++              add  7 to cell #1
    > +++++ +++++           add 10 to cell #2
    > +++                   add  3 to cell #3
    > +                     add  1 to cell #4
    <<<< -                  decrement counter (cell #0)
]
> ++ .                  print 'H'
> + .                   print 'e'
+++++ ++ .              print 'l'
.                       print 'l'
+++ .                   print 'o'
> ++ .                  print ' '
<< +++++ +++++ +++++ .  print 'W'
> .                     print 'o'
+++ .                   print 'r'
----- - .               print 'l'
----- --- .             print 'd'
> + .                   print '!'
> .                     print '\n'
EOF
```

Running the interpreter will print the AST of the Brainfuck program.

```
$ cargo run brainfuck -q -- hello.bf
[Add, Add, Add, Add, Add, Add, Add, Add, Add, Add, Loop([Right, Add, Add, Add, Add,
Add, Add, Add, Right, Add, Add, Add, Add, Add, Add, Add, Add, Add, Add, Right, Add,
Add, Add, Right, Add, Left, Left, Left, Left, Sub]), Right, Add, Add, Write, Right,
Add, Write, Add, Add, Add, Add, Add, Add, Add, Write, Write, Add, Add, Add, Write,
Right, Add, Add, Write, Left, Left, Add, Add, Add, Add, Add, Add, Add, Add, Add,
Add, Add, Add, Add, Add, Add, Write, Right, Write, Add, Add, Add, Write, Sub, Sub,
Sub, Sub, Sub, Sub, Write, Sub, Sub, Sub, Sub, Sub, Sub, Sub, Sub, Write, Right,
Add, Write, Right, Write]
```

So far so good, we will deal with optimization later and jump right into the execution.

### Execution

```rust
// machine.rs

use std::io::{Read, Write};

use crate::ast::{Instruction::*, Program};

/// Holds the state of the execution
pub struct Machine {
    /// Points at the current tape cell
    head: usize,
    /// Holds the program's memory, called tape
    tape: [u8; 30_000],
}

impl Machine {
    /// Creates a new Brainfuck machine
    pub fn new() -> Machine {
        Machine {
            // The machine starts with the head pointing
            // at the first cell
            head: 0,
            // All cells are initially set to `0`
            tape: [0; 30_000],
        }
    }

    /// Executes a Brainfuck program
    pub fn run(&mut self, program: &Program) {
        // Iterate through all instructions
        for ins in program.iter() {
            // Match on the instruction variants
            match ins {
                // Get the current cell's value and add or subtract 1 to/from it
                // and store the result.
                // Use wrapping_add to safely wrap around the cell's value range
                // of 0-255
                Add => self.tape[self.head] = self.tape[self.head].wrapping_add(1),
                Sub => self.tape[self.head] = self.tape[self.head].wrapping_sub(1),

                // Move the tape head and wrap it around 30_000 because that's the
                // size of the tape
                Right => self.head = (self.head + 1) % 30_000,
                Left => self.head = (self.head - 1) % 30_000,

                // Read one byte from STDIN and store it in the current cell
                Read => {
                    if let Some(c) = std::io::stdin()
                        .bytes()
                        .next()
                        .and_then(|result| result.ok())
                    {
                        self.tape[self.head] = c;
                    }
                }

                // Take the current cell's value, print it and flush STDOUT
                // to make sure it is printed immediately
                Write => {
                    print!("{}", self.tape[self.head] as char);
                    std::io::stdout().flush().unwrap();
                }

                // Repeat the loop body while the current cell is not 0
                // by calling the run function recursively
                Loop(body) => {
                    while self.tape[self.head] != 0 {
                        self.run(body);
                    }
                }
            }
        }
    }
}
```

Now all that's left is changing our `main()` function to create a `Machine` and have it run the program.

```rust
fn main() {
    // ...
    let mut machine = Machine::new();
    machine.run(&program);
}
```

If we run the "Hello World" program again we see the following:

```
$ cargo run brainfuck -q -- hello.bf
Hello World!
```

## Optimizations
