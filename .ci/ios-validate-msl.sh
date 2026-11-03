#!/bin/bash -e

# Compiles every .metal file in the provided directory with the iOS Metal compiler.
# The runtime compiles the generated shaders with MSL 2.4 (iOS 16), use the same version here.

SHADER_DIR="$1"
failures=0
count=0
for shader in "$SHADER_DIR"/*.metal; do
    count=$((count + 1))
    if ! xcrun -sdk iphoneos metal -std=ios-metal2.4 -Werror=return-type -c "$shader" \
            -o /dev/null 2> compile.log; then
        echo "::error file=$shader::Failed to compile $(basename "$shader")"
        cat compile.log
        failures=$((failures + 1))
        if [ $failures -ge 10 ]; then
            echo "Too many failures, stopping"
            break
        fi
    fi
done

echo "Compiled $count shaders, $failures failures"
[ $failures -eq 0 ]
