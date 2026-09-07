# Is macOS purgeable space worth chasing?

The header shows a purgeable figure next to free space. On iOS, the equivalent
pool turned out to be reclaimable under sustained write pressure, and that
finding became a product. The obvious next question was whether the same trick
is worth building for macOS.

It is not. This is the measurement that says so, kept because a number in the
interface that nobody has tested is how the iOS version nearly shipped a
promise it could not keep.

## What the figure is

`DiskSize.purgeableSpace()` is not a system-reported quantity. It is a
subtraction:

```
purgeable = volumeAvailableCapacityForImportantUsage - volumeAvailableCapacity
```

macOS reports a larger figure for "important usage" than for plain free space,
and the gap is what it believes it could give back if something important
needed room. It is an estimate, not an allocation.

## The test

MacBook, 245 GB container, macOS 26, **no APFS local snapshots** (`tmutil
listlocalsnapshots /` empty), so the whole figure was cache eviction rather
than snapshots.

Starting state:

```
free = 55.38 GB    important = 58.94 GB    purgeable = 3.55 GB
```

6.44 GB was written to the volume in 1 GB chunks — comfortably more than the
whole purgeable pool — sampling after each chunk, then deleted.

```
written    free       purgeable   free spent
1.07 GB    54.31 GB   3.55 GB     1.07 GB
2.15 GB    53.24 GB   3.55 GB     2.15 GB
3.22 GB    52.16 GB   3.55 GB     3.22 GB
4.29 GB    51.08 GB   1.11 GB     4.30 GB
5.37 GB    50.01 GB   1.11 GB     5.38 GB
6.44 GB    48.93 GB   1.11 GB     6.45 GB
```

## What it shows

**Free space fell by exactly what was written.** 6.45 GB spent for 6.44 GB
written. Not one byte came out of the purgeable pool; every byte came out of
real free space.

**The purgeable figure fell anyway**, by 2.44 GB, at the fourth chunk. Since
free space was falling at the full rate at the same time, that drop is macOS
*lowering its own estimate* of what it could purge — not macOS handing any of
it over.

**It came back on its own.** After the test files were deleted, free space
returned to 55.37 GB and purgeable returned to 3.55 GB without anything being
asked of it. A pool that refills itself when the pressure stops was never
spent.

## What this does not show

The test ran with 50 GB free. macOS may well evict for real when free space is
genuinely low — a few GB rather than fifty. Proving that needs the disk filled
to the edge, which is not a thing to do to a machine somebody works on.

So the honest claim is narrow: **at comfortable free-space levels the purgeable
figure buys you nothing, and it moves on its own.** It is not a reserve you can
plan around.

## Why the feature was not built

Beyond the measurement, the two platforms are not analogous:

On iOS the eviction trick is the *only* lever. The files are unreachable; you
cannot delete a cache you cannot see, so making the system evict it is the
whole product.

On macOS this app already deletes those caches directly, by path, and shows you
which ones first. Making the OS guess at the same job would be a worse version
of something already done better.

## What was built instead

The header figure now explains itself, because the confusing thing users
actually hit is Finder claiming free space they cannot use. Explaining the
number is worth more than pretending to command it.
