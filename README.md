# IPL 2026 Bowling Analytics: Context-Aware Performance Framework

A ball by ball SQL analytics pipeline that goes beyond raw economy rates and wicket counts to evaluate how bowlers actually performed relative to what each match demanded of them.

Built using MySQL and Python across 17,455 deliveries from all 74 IPL 2026 matches.

---

## The Problem with Traditional Bowling Stats

A bowler finishing with an economy of 8.5 looks fine on paper. But if the innings run rate was 11, that same bowler was actually restricting the opposition massively. Conversely, 8.5 in an innings where teams averaged 7 per over means they were leaking runs.

Similarly, taking the wicket of a number 11 batter who averages 4 is very different from dismissing a batter averaging 55, even though both show up as "1 wicket" in the scorecard.

This project builds metrics that account for that context.

---

## Key Findings (IPL 2026)

**Best overall bowler:** Bhuvneshwar Kumar (RCB), combined z-score of +3.02 across 16 matches and 63 overs. Elite in both economy and wicket quality across all phases and pitch types.

**Biggest surprise:** Sakib Hussain (SRH) finished 3rd overall with a +2.53 score across 11 matches. Best economy impact in the dataset at +2.05 standard deviations above average.

**Most fascinating contrast:** Shardul Thakur had a -1.99 z-economy (leaking runs consistently) but a +2.80 z-wicket score (taking quality wickets). Pure wicket buyer, expensive but match-defining when he strikes.

**Rashid Khan's pitch dependency:** Averaging -0.46 economy impact in the first innings but +1.96 in the second. Genuinely more valuable in chase situations than when defending a total.

**Bumrah problem:** +1.44 economy impact but only 4 wickets across 49 overs drags his combined score to -0.93. The metric exposes a genuine limitation: death over specialists take fewer wickets by nature of bowling when batters swing freely, not because they are ineffective.

---

## Metrics Built

### First Innings: Economy Differential

```
Economy Diff = Innings RR - Bowler Economy
```

Compares a bowler's economy against the final innings run rate. Positive means they were more economical than the innings average. Negative means they leaked more than average.

Innings RR is used as a hindsight baseline. Acknowledged limitation: a bowler's own performance partly shapes the innings RR, introducing mild circularity. Accepted as a practical tradeoff since all alternatives carry similar or worse issues.

### Second Innings: Over Impact

```
Over Impact = Required RR at start of over - Runs conceded that over
```

For each over in the second innings, compares runs conceded against what the batting side actually needed at that moment. Calculated over by over rather than across the whole spell, so it captures how the required rate changed dynamically throughout the chase.

Required RR is capped at 36 to handle edge cases where teams need impossible rates late in a chase.

### Wicket Impact

```
Wicket Value = Dismissed batter's IPL 2026 average
Wicket Impact per Over = Sum of wicket values / Total overs bowled
```

Each wicket is valued by the quality of the batter dismissed. Dismissing Virat Kohli (average 56) is worth more than dismissing a tail ender averaging 6. Batter averages were manually sourced and reconciled across all 10 teams (202 players).

Only credited to the bowler for: caught, bowled, lbw, stumped. Run outs and hit wickets excluded.

### Combined Z-Score

Both economy impact and wicket impact are normalized to z-scores (standard deviations from the mean) before combining. This prevents wicket impact from dominating the combined score simply because its raw numbers are larger.

```
Combined Score = Z-Economy + Z-Wicket
```

A score of +2 means the bowler was 2 standard deviations above the average bowler across both dimensions combined.

---

## Phase and Pitch Breakdown

All metrics are broken down by:

- Phase: Powerplay (overs 0-5), Middle (6-14), Death (15-19)
- Innings: first or second
- Pitch surface type: Black soil, Red soil, Grassy/loam, Clay-heavy loam, mixed variants

Venue pitch classifications were sourced and applied to all 13 IPL 2026 venues, enabling bowler recommendations conditioned on ground type.

---

## Tech Stack

- MySQL 8.0 for all data storage, transformation and analysis
- Python (pandas, SQLAlchemy) for ETL from raw CSV to MySQL
- Key SQL concepts used: CTEs, window functions, self joins, UNION ALL, z-score normalization via CROSS JOIN aggregation, conditional aggregation with CASE WHEN

---

## Project Structure

```
ipl_bowling_analytics.sql   - Full SQL pipeline in execution order (11 sections)
batter_averages_v2.csv      - IPL 2026 batter averages (202 players, all 10 teams)
venue_details_clean.csv     - Pitch surface classifications for all 13 venues
bowler_metadata_clean.csv   - Bowler type metadata (pace/spin, bowling hand)
ipl_2026_final_bbb.csv      - Ball by ball data (source)
```

---

## SQL Pipeline Overview

The full pipeline is in `ipl_bowling_analytics.sql`. It runs in 11 sequential sections:

1. Database setup
2. Deliveries table enrichment: total overs, innings RR, runs needed before over, required RR, bowler runs per over, over impact, pitch surface type
3. First innings economy impact table
4. Second innings economy impact table
5. Phase impact table (both innings, all phases)
6. Wicket impact tables
7. Overall impact combining both innings weighted by overs bowled
8. Z-score scaled final rankings
9. Master summary table combining all metrics
10. Pitch conditioned phase impact table
11. Useful analysis queries

---

## Key Design Decisions and Tradeoffs

**Why separate first and second innings metrics?**
The two innings have fundamentally different baselines. First innings has no target so the innings run rate is the only available reference. Second innings has a live required rate that changes ball by ball, which is a far more accurate baseline for evaluating containment. Merging them into one metric would produce misleading comparisons.

**Why z-scores instead of min-max scaling?**
Min-max scaling compresses all values between 0 and 1 relative to the best and worst in the dataset. One extreme outlier distorts everyone else's score. Z-scores measure distance from the mean in standard deviation units, which is robust to outliers and keeps the scale interpretable: 0 is average, +2 is excellent, -2 is poor.

**Why wicket value based on batter average rather than batting position?**
Position weights are too coarse. A genuine number 4 averaging 45 and a promoted number 4 averaging 12 are valued the same under position weighting. Using the actual batter average captures quality directly.

**Why COUNT(DISTINCT CONCAT(match_id, '-', FLOOR(over))) for over counting?**
MySQL's COUNT(DISTINCT) only accepts one argument. To count unique match-over combinations correctly, the two values are concatenated into a single string first. Without this, over 5 from match 1 and over 5 from match 20 would be treated as the same over.

---

## Limitations

- First innings baseline has mild circularity: the bowler's own performance partly determines the innings RR they are compared against
- Small sample sizes for specific pitch type and phase combinations, particularly for bowlers who played fewer matches
- Wicket impact metric penalizes death over specialists who bowl when batters swing freely and wickets are naturally rarer
- Batter averages are IPL 2026 season averages only, not career averages, so early season averages for players who improved later in the tournament may undervalue some wickets

---

## Data Source
- Ball by ball data sourced from Kaggle ([IPL 2026 ball by ball dataset](https://www.kaggle.com/datasets/sahiltailor/ipl-2024-ball-by-ball-dataset)).
- To replicate, download the deliveries CSV from Kaggle, load it into  MySQL as the `deliveries` table, and run `ipl_bowling_analytics.sql` in order.
