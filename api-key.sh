#!/bin/bash

# Function to generate a secure random token
generate_token() {
  local token_length=64
  # Generate random bytes, encode them in base64, keep special characters, and truncate to the desired length
  local token=$(openssl rand -base64 $((token_length * 3 / 4 + 1)) | head -c $token_length)
  echo "$token"
}

# Generate and display the token
new_token=$(generate_token)
echo "$new_token"
