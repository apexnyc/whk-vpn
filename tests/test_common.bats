#!/usr/bin/env bats

setup() {
  REPO_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/.." && pwd )"
  # shellcheck source=../lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
}

@test "generate_password returns exactly 32 characters" {
  run generate_password
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 32 ]
}

@test "generate_password includes all four character classes" {
  for _ in $(seq 1 20); do
    pw="$(generate_password)"
    [[ "$pw" =~ [a-z] ]]
    [[ "$pw" =~ [A-Z] ]]
    [[ "$pw" =~ [0-9] ]]
    [[ "$pw" =~ [@#%^*_+=-] ]]
  done
}

@test "generate_password produces different values on each call" {
  a="$(generate_password)"
  b="$(generate_password)"
  [ "$a" != "$b" ]
}

@test "validate_port accepts a normal high port" {
  run validate_port 44921
  [ "$status" -eq 0 ]
}

@test "validate_port rejects 51820, WireGuard's registered port" {
  run validate_port 51820
  [ "$status" -eq 1 ]
}

@test "validate_port rejects privileged ports" {
  run validate_port 80
  [ "$status" -eq 1 ]
}

@test "validate_port rejects out-of-range ports" {
  run validate_port 70000
  [ "$status" -eq 1 ]
}

@test "validate_port rejects non-numeric input" {
  run validate_port abcd
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 accepts a valid address" {
  run validate_ipv4 203.0.113.42
  [ "$status" -eq 0 ]
}

@test "validate_ipv4 rejects an octet above 255" {
  run validate_ipv4 203.0.113.999
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 rejects a three-octet address" {
  run validate_ipv4 203.0.113
  [ "$status" -eq 1 ]
}

@test "validate_ipv4 rejects arbitrary text" {
  run validate_ipv4 not-an-ip
  [ "$status" -eq 1 ]
}
