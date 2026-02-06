#!/bin/bash

# Find all files matching the pattern *_2_1.out
for file in *_2_1.out; do
    # Check if any files match (in case there are none)
    if [ ! -e "$file" ]; then
        echo "No files matching *_2_1.out found"
        exit 1
    fi
    
    # Extract the base name by removing _2_1.out
    # This replaces "_2_1.out" with ".out"
    newname="${file/_2_1.out/.out}"
    
    # Back up the original _2_1.out file before renaming
    backup="${file}.bak"
    cp "$file" "$backup"
    echo "Backed up: $file -> $backup"
    
    # Rename the file (overwriting the old one if it exists)
    mv "$file" "$newname"
    echo "Renamed: $file -> $newname"
done

echo "Done!"