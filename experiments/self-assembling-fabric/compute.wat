(module
  (func (export "sum_squares") (param $start i64) (param $end i64) (result i64)
    (local $i i64)
    (local $sum i64)
    local.get $start
    local.set $i
    i64.const 0
    local.set $sum
    block $done
      loop $loop
        local.get $i
        local.get $end
        i64.gt_s
        br_if $done
        local.get $sum
        local.get $i
        local.get $i
        i64.mul
        i64.add
        local.set $sum
        local.get $i
        i64.const 1
        i64.add
        local.set $i
        br $loop
      end
    end
    local.get $sum
  )
)
