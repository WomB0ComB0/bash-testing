#!/usr/bin/env bash

u32le() {
  local n=$1 out
  
  # convert number into 4 octets
  # ex: input = 0x12345678
  # octet1: 0x12
  # octet2: 0x34
  # octet3: 0x56
  # octet4: 0x78
  local octet1=$(( (n >> 24) & 0xFF))
  local octet2=$(( (n >> 16) & 0xFF))
  local octet3=$(( (n >> 8) & 0xFF))
  local octet4=$(( (n >> 0) & 0xFF))

  printf -v out '\\x%02x\\x%02x\\x%02x\\x%02x' \
    "$octet4" \
    "$octet3" \
    "$octet2" \
    "$octet1"
  
  printf '%b' "$out"
}