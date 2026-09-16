# Value keys the chart does not define. A chart node that is null, empty or a list is free-form
# (a probe handler, a volume) and is not descended into; anything else must match the chart's
# values.yaml, so a renamed or misspelled key fails CI instead of being silently ignored.
def unknown($chart; $path):
  to_entries
  | map(
      . as $e
      | if ($chart | has($e.key) | not) then [(($path + [$e.key]) | join("."))]
        elif ($e.value | type) == "object" and (($chart[$e.key] | type) == "object") and (($chart[$e.key] | length) > 0)
          then ($e.value | unknown($chart[$e.key]; $path + [$e.key]))
        else [] end
    )
  | add // [];
unknown($c[0]; [])
