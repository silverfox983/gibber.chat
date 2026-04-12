import re
import sys

with open("lib/services/auth_service.dart", "r") as f:
    content = f.read()

# The file has a broken syntax around line 3076-3085. Let's clean it up properly.
# Looking at the error messages, there's multiple >>> REPLACE markers left in the file.
# Let's completely remove them and fix the target function.

content = re.sub(r'>>>>\+\+\+ REPLACE[\s\S]*?(?=  // Next method)', '', content)
content = re.sub(r'>>>>\+\+\+ REPLACE', '', content)

with open("lib/services/auth_service.dart", "w") as f:
    f.write(content)

print("Done")
