(component
 (component $api
  (type $request (record (field "enabled" bool) (field "offset" s32) (field "challenge" string)))
  (type $response (record (field "fingerprint" u32) (field "enabled" bool)))
  (type $octets (list u8))
  (export $request-export "request" (type $request))
  (export $response-export "response" (type $response))
  (export $octets-export "octets" (type $octets))
  (core module $implementation
    (memory (export "memory") 1 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) i32.const 1024)
    (func (export "challenge-record")
      (param $enabled i32) (param $offset i32) (param $pointer i32) (param $length i32) (result i32)
      (local $hash i32) (local $index i32)
      i32.const -2128831035 local.set $hash
      block $done
        loop $loop
          local.get $index local.get $length i32.ge_u br_if $done
          local.get $hash local.get $pointer local.get $index i32.add i32.load8_u
          i32.xor i32.const 16777619 i32.mul local.set $hash
          local.get $index i32.const 1 i32.add local.set $index
          br $loop
        end
      end
      i32.const 0 local.get $hash local.get $offset i32.add i32.store
      i32.const 4 local.get $enabled i32.store8
      i32.const 0)
    (func (export "echo-octets") (param $pointer i32) (param $length i32) (result i32)
      i32.const 0 local.get $pointer i32.store
      i32.const 4 local.get $length i32.store
      i32.const 0)
    (func (export "finish")))
  (core instance $instance (instantiate $implementation))
  (func (export "challenge-record") (param "request" $request-export) (result $response-export)
    (canon lift (core func $instance "challenge-record")
      (memory (core memory $instance "memory")) (realloc (core func $instance "realloc"))))
  (func (export "finish") (canon lift (core func $instance "finish")))
  (func (export "echo-octets") (param "octets" $octets-export) (result $octets-export)
    (canon lift (core func $instance "echo-octets")
      (memory (core memory $instance "memory")) (realloc (core func $instance "realloc"))))
 )
 (instance $api-instance (instantiate $api))
 (export "proof:typed/api@0.1.0" (instance $api-instance))
)
