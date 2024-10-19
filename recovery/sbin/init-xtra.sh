# Additional functions for init - not essential for the common case.


unpack_apkovl() {
	local ovl="$1"

	ovlfiles=/tmp/ovlfiles

  tar -C /sysroot -zxvf "$ovl" > $ovlfiles
  return $?
}

# Verify the signature of a file using a public key.
verify() {
  file_to_verify="$1"
  signature_file="$2"
  public_key_file="$3"

  # Calculate the SHA256 hash of the file
  sha256_hash=$(sha256sum "$file_to_verify" | awk '{print $1}')

  # Verify the signature using the public key
  openssl dgst -sha256 -verify "$public_key_file" -signature "$signature_file" <(echo "$sha256_hash")

  #minisign -Vm <file> -P RWSpi0c9eRkLp+M2v00IqZhHRq2sCG6snS3PkDu99XzIe3en5rZWO9Yq

  # Check the verification result
  if [[ $? -eq 0 ]]; then
    echo "Verification successful!"
  else
    echo "Verification failed!"
  fi
}


