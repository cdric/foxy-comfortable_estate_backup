find ../public_html/gocozyhomes/uploads -type f -regextype posix-extended -regex '.*__[0-9]{8}_[0-9]{6}.*\.(jpeg|jpg|JPG)' -printf "%s %p\n" | \
awk '
{
  if (match($2, /__([0-9]{4})([0-9]{2})[0-9]{2}_/, m)) {
    key = m[1] "-" m[2];
    sizes[key] += $1;
    total += $1;
  }
}
END {
  for (date in sizes) {
    printf "%s: %.2f GB\n", date, sizes[date] / (1024 * 1024 * 1024);
  }
  printf "Total: %.2f GB\n", total / (1024 * 1024 * 1024);
}' | sort
