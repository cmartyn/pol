// Sorted x positions grouped wherever neighbours sit within `gap` pixels.
// The race and chamber timelines use it so corrections a few days apart
// share one label instead of printing over each other.
export function clusters(xs, gap) {
  const groups = []
  for (const x of [...xs].sort((a, b) => a - b)) {
    const group = groups[groups.length - 1]
    if (group && x - group[group.length - 1] < gap) group.push(x)
    else groups.push([x])
  }
  return groups
}
