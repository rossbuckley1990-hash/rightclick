(component
  (core module $implementation
    (memory (export "memory") 1 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) i32.const 1024)
    (func (export "trap") (param i32 i32) (result i32) unreachable))
  (core instance $instance (instantiate $implementation))
  (func (export "trap") (param "challenge" string) (result u32)
    (canon lift (core func $instance "trap")
      (memory (core memory $instance "memory")) (realloc (core func $instance "realloc"))))
)
