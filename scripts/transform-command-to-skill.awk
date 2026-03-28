BEGIN {
  in_front = 0
  in_args = 0
  past_front = 0
}

# First --- opens frontmatter
/^---$/ && !in_front && !past_front {
  in_front = 1
  print
  next
}

# Second --- closes frontmatter
/^---$/ && in_front {
  in_front = 0
  past_front = 1
  in_args = 0
  print
  next
}

# Inside frontmatter: skip arguments block
in_front && /^arguments:/ {
  in_args = 1
  next
}

# Inside arguments block: skip indented lines (nested YAML)
in_front && in_args && /^[[:space:]]/ {
  next
}

# Inside arguments block: non-indented line ends the block
in_front && in_args && !/^[[:space:]]/ {
  in_args = 0
}

# Inside frontmatter: prefix name
in_front && /^name: / {
  sub(/^name: /, "name: cmd-")
  print
  next
}

# Inside frontmatter: pass through other fields
in_front {
  print
  next
}

# Body: replace template variables
past_front {
  gsub(/\{\{[^}]+\}\}/, "$ARGUMENTS")
  print
}
