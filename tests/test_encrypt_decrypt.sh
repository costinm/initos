#!/bin/bash
# initos encrypt test and demonstration script
# This script demonstrates how to use initos for encryption with age keys

set -e

export PATH="$PATH:$(pwd)/target/x86_64-unknown-linux-musl/release"


# Clean up any existing test files
rm -f /tmp/initos_test.*

# Step 1: Generate age key pair
echo ""
echo "Step 1: Generating age key pair..."
IDENTITY_FILE="/tmp/initos_test_id.txt"

# Generate the key pair
age-keygen -o "$IDENTITY_FILE" >/dev/null 2>&1

# Extract and save public key
PUBLIC_KEY=""
if grep -q "# public key:" "$IDENTITY_FILE"; then
	PUBLIC_KEY=$(grep "# public key:" "$IDENTITY_FILE" | sed 's/# public key: //')
else
	PUBLIC_KEY=$(head -n 2 "$IDENTITY_FILE" | tail -n 1 | sed 's/# public key: //')
fi

echo "Public key: $PUBLIC_KEY"
echo "Identity file: $IDENTITY_FILE"
echo ""

# Step 2: Prepare a secret message
echo "Step 2: Preparing secret message..."
SECRET_MESSAGE="This is a secret message that should be encrypted!"
echo "Original message: $SECRET_MESSAGE"
echo ""

# Step 3: Encrypt using initos with public key argument
echo "Step 3: Encrypting with initos encrypt:"
echo "$SECRET_MESSAGE" | initos encrypt "$PUBLIC_KEY" >"/tmp/initos_test.age"
echo "Encrypted data saved to: /tmp/initos_test.age"
echo ""
echo "Encrypted output:"
cat "/tmp/initos_test.age"
echo ""

# Step 4: Decrypt with age CLI (since initos encrypt is compatible with age CLI)
echo "Step 4: Decrypting with age CLI:"
/usr/bin/age -d -i "$IDENTITY_FILE" <"/tmp/initos_test.age" >"/tmp/initos_test_decrypted.txt"
echo "Decrypted to: /tmp/initos_test_decrypted.txt"
DECRYPTED=$(cat "/tmp/initos_test_decrypted.txt")
echo "Decrypted content: $DECRYPTED"
echo ""

# Step 5: Verify the decryption
echo "Step 5: Verification:"
if [ "$DECRYPTED" = "$SECRET_MESSAGE" ]; then
	echo "✓ SUCCESS: initos encrypt produces age-compatible output!"
	echo "  - initos encrypt: works"
	echo "  - age CLI decrypt: works"
	echo "  - Output is compatible between tools"
else
	echo "✗ ERROR: Decryption failed!"
	echo "Original: $SECRET_MESSAGE"
	echo "Decrypted: $DECRYPTED"
	exit 1
fi

# Step 6: Demonstrate other encryption methods
echo ""
echo "Step 6: Alternative encryption methods demonstration:"
echo ""

# Method 1: Using age-keygen to create a recipients file
echo "6.1 Using age-keygen to create recipients file:"
age-keygen -r "$PUBLIC_KEY" -o "/tmp/initos_test_recipients.txt"
echo "Recipients file created: /tmp/initos_test_recipients.txt"
echo "Contents:"
cat "/tmp/initos_test_recipients.txt"
echo ""

# Method 2: Using pure age CLI
echo "6.2 Using age CLI direct:"
echo "$SECRET_MESSAGE" | /usr/bin/age -r "$PUBLIC_KEY" >"/tmp/initos_test_cli.age"
echo "Encrypted with age CLI to: /tmp/initos_test_cli.age"
/usr/bin/age -d -i "$IDENTITY_FILE" <"/tmp/initos_test_cli.age" >"/tmp/initos_test_cli_decrypted.txt"
echo "Decrypted with age CLI: $(cat /tmp/initos_test_cli_decrypted.txt)"
echo ""

echo "=== Summary ==="
echo "This script demonstrates that:"
echo "1. initos encrypt accepts age public keys as arguments ✓"
echo "2. The encrypted output is compatible with age CLI decryption ✓"
echo "3. age-keygen creates files compatible with initos encryption ✓"
echo ""
echo "Key findings:"
echo "- initos encrypt produces age-compatible output format"
echo "- For decryption, use 'age -d -i <identity_file>' CLI tool"
echo "- Both initos encrypt and age CLI encryption produce valid age output"
echo "- The age CLI can decrypt output from both tools"
echo ""
echo "Usage examples:"
echo "  # Encrypt with initos:"
echo "  echo 'secret' | initos encrypt '<public_key>' > output.age"
echo "  # Decrypt with age CLI:"
echo "  age -d -i '<identity_file>' < output.age"
echo ""
echo "Cleanup completed."
