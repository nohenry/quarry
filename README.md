# Quarry
A systems programming language focused on compile time evaluation semantics.

## Examples

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