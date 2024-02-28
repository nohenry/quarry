# Quarry
A systems programming language focused on compile time evaluation semantics.

## Examples

### Types
```zig
let A = int8      // signed 8 bit integer
let B = uint64    // unsigned 64 bit integer
let C = uint      // unsigned pointer-sized integer
let D = float64   // 64 bit float
let E = int&      // int reference 
let F = int mut&  // mutable int reference 
let G = int?      // optional int 
let H = [int: 4]  // array of 4 ints 
let I = [int]     // slice of ints (reference and length) 
let J = [mut int] // mutable slice of ints
let K = type [a: int, b: float, c: bool] // record/struct
let L = type A | B | C // tagged union
let M = type(uint8) A: uint8 = 1 | B: float = 3 | bool // tagged union

let N = int8      // weak type alias
let O = type int8 // strong type alias
```

### Constant Evaluation
```zig
let sum = (int mut until) int {
    let mut sum = 0
    loop until >= 0 {
        sum += until
        until -= 1
    }

    sum
}

let mysum = const sum(10) // equals 55
```

### Miscellaneous 
```zig
let b = const a
let c = const b
let d = const c
int32 a = 3

let array_size = () int8 { 4 }

let main = (int8 argc) int8 {
    [int8: array_size()] arr = [1, 2, 3]
    0
}
```


```zig
let value = const sum()

let MySize = uint?mut &?

let main = (int8 foo = 23) int8 {
    let foo1 = [foo, a, 1, 2]
}

let f = main(2)

let Foo = Data
let Data = type(int) uint A | B
```