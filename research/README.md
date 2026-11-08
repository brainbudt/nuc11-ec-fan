# Research

The experiments behind the main README's [Evidence](../README.md#evidence) section. They write to the EC, so read them before running anything.

| File | Purpose |
| --- | --- |
| `fan-write-test.sh` | One-shot test: record 1 min duty 50 → 70 % for 30 s, then restore |
| `fan-sweep-test.sh` | Pre-registered controlled sweep (frozen in commit `fb7d3ab`); CSV on stdout |
| `analyze-sweep.py` | Evaluates a sweep log against the fixed criteria C1–C7 |
| `results/run1-exploratory.csv` | Earlier sweep with 30 s holds; failed its own C4, kept for transparency |
| `results/run2-confirmatory.csv` | Confirmatory sweep |
| `results/run2-analysis.txt` | Analyzer output for run 2 |
| `make_charts.py` | Renders the README charts (`docs/img/*.svg`, light and dark) from the run 2 log |

Both test scripts expect `ecmem` and `nuc-fan.sh` in `/tmp`. Set `ECMEM` and `NUCFAN` to use other paths. Every sample checks the written byte; any failure restores the original value. Exit status 2 means the restore could not be verified.

Re-run the analysis:

```sh
python3 analyze-sweep.py results/run2-confirmatory.csv
```
