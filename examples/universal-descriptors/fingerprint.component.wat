(component
  (core module $implementation
    (memory (export "memory") 1 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32)
      i32.const 1024)
    (func (export "challenge-fingerprint") (param $pointer i32) (param $length i32) (result i32)
      (local $hash i32) (local $index i32)
      i32.const -2128831035
      local.set $hash
      block $done
        loop $loop
          local.get $index
          local.get $length
          i32.ge_u
          br_if $done
          local.get $hash
          local.get $pointer
          local.get $index
          i32.add
          i32.load8_u
          i32.xor
          i32.const 16777619
          i32.mul
          local.set $hash
          local.get $index
          i32.const 1
          i32.add
          local.set $index
          br $loop
        end
      end
      local.get $hash))
  (core instance $instance (instantiate $implementation))
  (func (export "challenge-fingerprint") (param "challenge" string) (result u32)
    (canon lift (core func $instance "challenge-fingerprint")
      (memory (core memory $instance "memory")) (realloc (core func $instance "realloc"))))
)
