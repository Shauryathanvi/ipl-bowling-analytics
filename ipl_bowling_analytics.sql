-- ============================================================
-- IPL 2026 BOWLING ANALYTICS PROJECT
-- Complete SQL Pipeline in Execution Order
-- ============================================================
-- Prerequisites before running this file:
-- 1. Load deliveries CSV into MySQL as the `deliveries` table via Python/SQLAlchemy
-- 2. Load batter_averages_v2.csv into MySQL as `batter_averages` via Python/SQLAlchemy
-- 3. Load venue_details_clean.csv into MySQL as `venue_details` via Python/SQLAlchemy
-- 4. Load bowler_metadata_clean.csv into MySQL as `bowler_metadata` via Python/SQLAlchemy
-- 5. Populate the `final_or_needed_score` column via the Python script provided
-- ============================================================


-- ------------------------------------------------------------
-- SECTION 0: SETTINGS
-- ------------------------------------------------------------

SET SQL_SAFE_UPDATES = 0;


-- ------------------------------------------------------------
-- SECTION 1: DATABASE SETUP
-- ------------------------------------------------------------

CREATE DATABASE cricket_db;
USE cricket_db;


-- ------------------------------------------------------------
-- SECTION 2: DELIVERIES TABLE ENRICHMENT
-- Add computed columns to the base ball-by-ball table
-- ------------------------------------------------------------

-- 2.1 Total overs in the match (hardcoded to 20, handle DLS separately)
ALTER TABLE deliveries
ADD COLUMN total_overs INT DEFAULT 20;

-- 2.2 Innings Run Rate (final score / total overs)
-- Used as baseline for first innings economy comparison
ALTER TABLE deliveries
ADD COLUMN innings_rr DECIMAL(4,2);

UPDATE deliveries
SET innings_rr = ROUND(final_or_needed_score / total_overs, 2);

-- 2.3 Runs needed before each over (second innings only)
-- Cumulative runs subtracted from target at start of each over
ALTER TABLE deliveries
ADD COLUMN runs_needed_before_over INT;

WITH over_runs AS (
    SELECT
        match_id,
        innings,
        FLOOR(`over`)              AS over_num,
        MAX(final_or_needed_score) AS target,
        SUM(runs_of_bat + extras)  AS runs_this_over
    FROM deliveries
    WHERE innings = 2
    GROUP BY match_id, innings, FLOOR(`over`), final_or_needed_score
),
cumulative AS (
    SELECT
        a.match_id,
        a.innings,
        a.over_num,
        a.target,
        a.target - COALESCE(SUM(b.runs_this_over), 0) AS runs_needed
    FROM over_runs a
    LEFT JOIN over_runs b
        ON a.match_id = b.match_id
        AND a.innings = b.innings
        AND b.over_num < a.over_num
    GROUP BY a.match_id, a.innings, a.over_num, a.target
)
UPDATE deliveries d
JOIN cumulative c
    ON d.match_id = c.match_id
    AND d.innings = c.innings
    AND FLOOR(d.`over`) = c.over_num
SET d.runs_needed_before_over = c.runs_needed
WHERE d.innings = 2;

-- 2.4 Required Run Rate at start of each over (second innings only)
-- Capped at 36 (maximum possible in cricket: 6 sixes per over)
ALTER TABLE deliveries
ADD COLUMN required_rr DECIMAL(5,2);

UPDATE deliveries
SET required_rr = LEAST(
    ROUND(runs_needed_before_over / (total_overs - FLOOR(`over`)), 2),
    36.00
)
WHERE innings = 2;

-- 2.5 Bowler runs conceded in each over (second innings only)
-- Excludes legbyes and byes since those are not the bowler's fault
ALTER TABLE deliveries
ADD COLUMN bowler_runs_this_over INT;

UPDATE deliveries d
JOIN (
    SELECT
        match_id,
        innings,
        bowler,
        FLOOR(`over`)                              AS over_num,
        SUM(runs_of_bat + extras - legbyes - byes) AS runs_given
    FROM deliveries
    WHERE innings = 2
    GROUP BY match_id, innings, bowler, FLOOR(`over`)
) calc
    ON d.match_id = calc.match_id
    AND d.innings = calc.innings
    AND d.bowler = calc.bowler
    AND FLOOR(d.`over`) = calc.over_num
SET d.bowler_runs_this_over = calc.runs_given
WHERE d.innings = 2;

-- 2.6 Over impact: required RR minus runs conceded that over (second innings only)
-- Positive = bowler beat the required rate (good)
-- Negative = bowler leaked more than required (bad)
ALTER TABLE deliveries
ADD COLUMN over_impact DECIMAL(5,2);

UPDATE deliveries
SET over_impact = ROUND(required_rr - bowler_runs_this_over, 2)
WHERE innings = 2;

-- 2.7 Fix inconsistent wicket type naming in source data
UPDATE deliveries
SET wicket_type = 'hitwicket'
WHERE wicket_type = 'hit wicket';

-- 2.8 Tag each delivery with pitch surface type from venue
ALTER TABLE deliveries
ADD COLUMN pitch_surface_type VARCHAR(50);

UPDATE deliveries d
JOIN venue_details v ON d.venue = v.venue_name
SET d.pitch_surface_type = v.pitch_surface_type;


-- ------------------------------------------------------------
-- SECTION 3: FIRST INNINGS ECONOMY IMPACT TABLE
-- Economy diff = innings RR - bowler economy
-- Positive = bowler was more economical than innings average
-- Negative = bowler leaked more than innings average
-- ------------------------------------------------------------

CREATE TABLE bowler_economy_impact_first_innings (
    match_id        INT,
    match_no        INT,
    bowler          VARCHAR(100),
    bowler_runs     INT,
    balls_bowled    INT,
    overs_bowled    DECIMAL(4,2),
    bowler_economy  DECIMAL(4,2),
    innings_rr      DECIMAL(4,2)
);

INSERT INTO bowler_economy_impact_first_innings
SELECT
    match_id,
    match_no,
    bowler,
    SUM(runs_of_bat + extras - legbyes - byes)        AS bowler_runs,
    COUNT(DISTINCT `over`)                             AS balls_bowled,
    ROUND(COUNT(DISTINCT `over`) / 6.0, 2)            AS overs_bowled,
    ROUND(SUM(runs_of_bat + extras - legbyes - byes)
          / COUNT(DISTINCT `over`) * 6, 2)            AS bowler_economy,
    MAX(innings_rr)                                    AS innings_rr
FROM deliveries
WHERE innings = 1
GROUP BY match_id, match_no, bowler;

ALTER TABLE bowler_economy_impact_first_innings
ADD COLUMN economy_diff DECIMAL(4,2);

UPDATE bowler_economy_impact_first_innings
SET economy_diff = ROUND(innings_rr - bowler_economy, 2);

-- Tournament average economy diff per bowler (first innings)
SELECT
    bowler,
    COUNT(match_id)              AS matches,
    ROUND(AVG(economy_diff), 2)  AS avg_economy_diff
FROM bowler_economy_impact_first_innings
GROUP BY bowler
ORDER BY avg_economy_diff DESC;


-- ------------------------------------------------------------
-- SECTION 4: SECOND INNINGS ECONOMY IMPACT TABLE
-- Over impact = required RR - runs conceded that over
-- Averaged per over bowled across the tournament
-- ------------------------------------------------------------

CREATE TABLE bowler_economy_impact_second_innings AS
SELECT
    bowler,
    COUNT(DISTINCT match_id)                                AS matches,
    COUNT(DISTINCT CONCAT(match_id, '-', over_num))         AS total_overs_bowled,
    ROUND(
        SUM(over_impact) /
        COUNT(DISTINCT CONCAT(match_id, '-', over_num))
    , 2)                                                    AS avg_over_impact
FROM (
    SELECT DISTINCT
        match_id,
        bowler,
        FLOOR(`over`) AS over_num,
        over_impact
    FROM deliveries
    WHERE innings = 2
) over_level
GROUP BY bowler
ORDER BY avg_over_impact DESC;


-- ------------------------------------------------------------
-- SECTION 5: PHASE IMPACT TABLE (both innings, all phases)
-- Breaks down economy impact by phase and innings
-- First innings: economy diff vs innings RR
-- Second innings: average over impact vs required RR
-- ------------------------------------------------------------

CREATE TABLE bowler_phase_impact AS

-- First innings
SELECT
    bowler,
    1 AS innings,
    CASE
        WHEN FLOOR(`over`) BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN FLOOR(`over`) BETWEEN 6 AND 14 THEN 'Middle'
        WHEN FLOOR(`over`) BETWEEN 15 AND 19 THEN 'Death'
    END AS phase,
    COUNT(DISTINCT match_id)                                          AS matches,
    COUNT(DISTINCT CONCAT(match_id, '-', FLOOR(`over`)))              AS overs_bowled,
    ROUND(AVG(innings_rr), 2)                                         AS baseline,
    ROUND(SUM(runs_of_bat + extras - legbyes - byes) /
          COUNT(DISTINCT CONCAT(match_id, '-', FLOOR(`over`))), 2)    AS bowler_economy,
    ROUND(AVG(innings_rr) -
          SUM(runs_of_bat + extras - legbyes - byes) /
          COUNT(DISTINCT CONCAT(match_id, '-', FLOOR(`over`))), 2)    AS impact
FROM deliveries
WHERE innings = 1
GROUP BY bowler, innings,
    CASE
        WHEN FLOOR(`over`) BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN FLOOR(`over`) BETWEEN 6 AND 14 THEN 'Middle'
        WHEN FLOOR(`over`) BETWEEN 15 AND 19 THEN 'Death'
    END

UNION ALL

-- Second innings
SELECT
    bowler,
    2 AS innings,
    CASE
        WHEN over_num BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN over_num BETWEEN 6 AND 14 THEN 'Middle'
        WHEN over_num BETWEEN 15 AND 19 THEN 'Death'
    END AS phase,
    COUNT(DISTINCT match_id)                                    AS matches,
    COUNT(DISTINCT CONCAT(match_id, '-', over_num))             AS overs_bowled,
    ROUND(AVG(required_rr), 2)                                  AS baseline,
    ROUND(SUM(bowler_runs_this_over) /
          COUNT(DISTINCT CONCAT(match_id, '-', over_num)), 2)   AS bowler_economy,
    ROUND(AVG(over_impact), 2)                                  AS impact
FROM (
    SELECT DISTINCT
        match_id, bowler, FLOOR(`over`) AS over_num,
        required_rr, bowler_runs_this_over, over_impact
    FROM deliveries
    WHERE innings = 2
) d
GROUP BY bowler,
    CASE
        WHEN over_num BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN over_num BETWEEN 6 AND 14 THEN 'Middle'
        WHEN over_num BETWEEN 15 AND 19 THEN 'Death'
    END

ORDER BY bowler, innings, phase;


-- ------------------------------------------------------------
-- SECTION 6: WICKET IMPACT TABLES
-- Wicket value = dismissed batter's IPL 2026 average
-- Excludes: run outs, hit wickets, retired hurt, obstructing field
-- Default value of 10 applied where batter not found in averages table
-- ------------------------------------------------------------

CREATE TABLE bowler_wicket_impact AS
SELECT
    d.match_id,
    d.match_no,
    d.innings,
    CASE
        WHEN FLOOR(d.`over`) BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN FLOOR(d.`over`) BETWEEN 6 AND 14 THEN 'Middle'
        WHEN FLOOR(d.`over`) BETWEEN 15 AND 19 THEN 'Death'
    END AS phase,
    d.bowler,
    d.player_dismissed,
    d.wicket_type,
    COALESCE(b.Average, 10) AS wicket_value
FROM deliveries d
LEFT JOIN batter_averages b
    ON d.player_dismissed = b.Player
WHERE d.wicket_type IN ('caught', 'bowled', 'lbw', 'stumped')
ORDER BY d.match_id, d.innings, d.`over`;

-- Wicket summary per bowler with phase breakdown
CREATE TABLE bowler_wicket_summary AS
SELECT
    w.bowler,
    w.matches,
    w.total_wickets,
    w.wickets_1st_innings,
    w.wickets_2nd_innings,
    w.wickets_pp_1st,
    w.wickets_mid_1st,
    w.wickets_death_1st,
    w.wickets_pp_2nd,
    w.wickets_mid_2nd,
    w.wickets_death_2nd,
    w.total_wicket_value,
    w.avg_wicket_quality,
    o.overs_bowled,
    ROUND(w.total_wicket_value / o.overs_bowled, 2) AS wicket_impact_per_over
FROM (
    SELECT
        bowler,
        COUNT(DISTINCT match_id)                                             AS matches,
        COUNT(player_dismissed)                                              AS total_wickets,
        SUM(CASE WHEN innings = 1 THEN 1 ELSE 0 END)                        AS wickets_1st_innings,
        SUM(CASE WHEN innings = 2 THEN 1 ELSE 0 END)                        AS wickets_2nd_innings,
        SUM(CASE WHEN innings = 1 AND phase = 'Powerplay' THEN 1 ELSE 0 END) AS wickets_pp_1st,
        SUM(CASE WHEN innings = 1 AND phase = 'Middle'    THEN 1 ELSE 0 END) AS wickets_mid_1st,
        SUM(CASE WHEN innings = 1 AND phase = 'Death'     THEN 1 ELSE 0 END) AS wickets_death_1st,
        SUM(CASE WHEN innings = 2 AND phase = 'Powerplay' THEN 1 ELSE 0 END) AS wickets_pp_2nd,
        SUM(CASE WHEN innings = 2 AND phase = 'Middle'    THEN 1 ELSE 0 END) AS wickets_mid_2nd,
        SUM(CASE WHEN innings = 2 AND phase = 'Death'     THEN 1 ELSE 0 END) AS wickets_death_2nd,
        ROUND(SUM(wicket_value), 2)                                          AS total_wicket_value,
        ROUND(AVG(wicket_value), 2)                                          AS avg_wicket_quality
    FROM bowler_wicket_impact
    WHERE player_dismissed IS NOT NULL
    GROUP BY bowler
) w
JOIN (
    SELECT
        bowler,
        COUNT(DISTINCT CONCAT(match_id, '-', innings, '-', FLOOR(`over`))) AS overs_bowled
    FROM deliveries
    GROUP BY bowler
) o ON w.bowler = o.bowler
ORDER BY wicket_impact_per_over DESC;


-- ------------------------------------------------------------
-- SECTION 7: OVERALL IMPACT TABLE
-- Combines first and second innings economy impact
-- Weighted by overs bowled in each innings so workload is
-- fairly represented in the final number
-- ------------------------------------------------------------

CREATE TABLE bowler_overall_impact AS
SELECT
    bowler,
    SUM(matches)                                AS total_matches,
    SUM(overs_bowled)                           AS total_overs,
    ROUND(
        SUM(overs_bowled * impact) /
        SUM(overs_bowled)
    , 2)                                        AS weighted_overall_impact
FROM (
    SELECT
        bowler,
        innings,
        SUM(matches)                                          AS matches,
        SUM(overs_bowled)                                     AS overs_bowled,
        ROUND(SUM(overs_bowled * impact) /
              SUM(overs_bowled), 2)                           AS impact
    FROM bowler_phase_impact
    GROUP BY bowler, innings
) innings_summary
GROUP BY bowler
HAVING SUM(overs_bowled) >= 15
ORDER BY weighted_overall_impact DESC;


-- ------------------------------------------------------------
-- SECTION 8: FINAL IMPACT TABLE WITH Z-SCORE SCALING
-- Combines economy and wicket impact normalized via z-scores
-- Z-score = (value - mean) / standard deviation
-- 0 = average, +2 = excellent, -2 = poor
-- Only includes bowlers with at least 1 wicket and 15+ overs
-- ------------------------------------------------------------

DROP TABLE IF EXISTS bowler_final_impact_scaled;

CREATE TABLE bowler_final_impact_scaled AS
SELECT
    bowler,
    total_matches,
    total_overs,
    total_wickets,
    economy_impact,
    wicket_impact_per_over,
    avg_wicket_quality,
    ROUND((economy_impact - stats.avg_eco) / stats.std_eco, 2)         AS z_economy,
    ROUND((wicket_impact_per_over - stats.avg_wkt) / stats.std_wkt, 2) AS z_wicket,
    ROUND(
        ((economy_impact - stats.avg_eco) / stats.std_eco) +
        ((wicket_impact_per_over - stats.avg_wkt) / stats.std_wkt)
    , 2)                                                                AS combined_z_score
FROM (
    SELECT
        e.bowler,
        COUNT(DISTINCT d.match_id)              AS total_matches,
        e.total_overs,
        COALESCE(w.total_wickets, 0)            AS total_wickets,
        e.weighted_overall_impact               AS economy_impact,
        COALESCE(w.avg_wicket_quality, 0)       AS avg_wicket_quality,
        COALESCE(w.wicket_impact_per_over, 0)   AS wicket_impact_per_over
    FROM bowler_overall_impact e
    JOIN bowler_wicket_summary w ON e.bowler = w.bowler
    JOIN deliveries d ON e.bowler = d.bowler
    WHERE e.total_overs >= 15
    GROUP BY e.bowler, e.total_overs, e.weighted_overall_impact,
             w.total_wickets, w.avg_wicket_quality, w.wicket_impact_per_over
) base
CROSS JOIN (
    SELECT
        AVG(economy_impact)         AS avg_eco,
        STD(economy_impact)         AS std_eco,
        AVG(wicket_impact_per_over) AS avg_wkt,
        STD(wicket_impact_per_over) AS std_wkt
    FROM (
        SELECT
            e.weighted_overall_impact                     AS economy_impact,
            COALESCE(w.wicket_impact_per_over, 0)         AS wicket_impact_per_over
        FROM bowler_overall_impact e
        JOIN bowler_wicket_summary w ON e.bowler = w.bowler
        WHERE e.total_overs >= 15
    ) stats_base
) stats
ORDER BY combined_z_score DESC;


-- ------------------------------------------------------------
-- SECTION 9: MASTER SUMMARY TABLE
-- One row per bowler with all metrics combined
-- Use this as the primary output table for analysis
-- ------------------------------------------------------------

CREATE TABLE bowler_master_summary AS
SELECT
    s.bowler,
    s.total_matches,
    s.total_overs,
    s.total_wickets,
    ROUND(AVG(CASE WHEN f.innings = 1 THEN f.impact END), 2) AS first_innings_economy_diff,
    ROUND(AVG(CASE WHEN f.innings = 2 THEN f.impact END), 2) AS second_innings_over_impact,
    s.economy_impact                                          AS combined_economy_impact,
    w.avg_wicket_quality,
    w.wickets_pp_1st,
    w.wickets_mid_1st,
    w.wickets_death_1st,
    w.wickets_pp_2nd,
    w.wickets_mid_2nd,
    w.wickets_death_2nd,
    s.wicket_impact_per_over,
    s.z_economy,
    s.z_wicket,
    s.combined_z_score                                        AS total_impact_score
FROM bowler_final_impact_scaled s
JOIN bowler_wicket_summary w ON s.bowler = w.bowler
JOIN bowler_phase_impact f   ON s.bowler = f.bowler
GROUP BY
    s.bowler, s.total_matches, s.total_overs,
    s.total_wickets, s.economy_impact,
    w.avg_wicket_quality, w.wickets_pp_1st,
    w.wickets_mid_1st, w.wickets_death_1st,
    w.wickets_pp_2nd, w.wickets_mid_2nd,
    w.wickets_death_2nd, s.wicket_impact_per_over,
    s.z_economy, s.z_wicket, s.combined_z_score
ORDER BY total_impact_score DESC;


-- ------------------------------------------------------------
-- SECTION 10: PITCH CONDITIONED PHASE IMPACT TABLE
-- Same as bowler_phase_impact but grouped by pitch surface type
-- Enables pitch-specific bowler performance analysis
-- ------------------------------------------------------------

CREATE TABLE bowler_pitch_phase_impact AS

-- First innings
SELECT
    bowler,
    1 AS innings,
    pitch_surface_type,
    CASE
        WHEN FLOOR(`over`) BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN FLOOR(`over`) BETWEEN 6 AND 14 THEN 'Middle'
        WHEN FLOOR(`over`) BETWEEN 15 AND 19 THEN 'Death'
    END AS phase,
    COUNT(DISTINCT match_id)                                          AS matches,
    COUNT(DISTINCT CONCAT(match_id, '-', FLOOR(`over`)))              AS overs_bowled,
    ROUND(AVG(innings_rr), 2)                                         AS baseline,
    ROUND(SUM(runs_of_bat + extras - legbyes - byes) /
          COUNT(DISTINCT CONCAT(match_id, '-', FLOOR(`over`))), 2)    AS bowler_economy,
    ROUND(AVG(innings_rr) -
          SUM(runs_of_bat + extras - legbyes - byes) /
          COUNT(DISTINCT CONCAT(match_id, '-', FLOOR(`over`))), 2)    AS impact
FROM deliveries
WHERE innings = 1
GROUP BY bowler, innings, pitch_surface_type,
    CASE
        WHEN FLOOR(`over`) BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN FLOOR(`over`) BETWEEN 6 AND 14 THEN 'Middle'
        WHEN FLOOR(`over`) BETWEEN 15 AND 19 THEN 'Death'
    END

UNION ALL

-- Second innings
SELECT
    bowler,
    2 AS innings,
    pitch_surface_type,
    CASE
        WHEN over_num BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN over_num BETWEEN 6 AND 14 THEN 'Middle'
        WHEN over_num BETWEEN 15 AND 19 THEN 'Death'
    END AS phase,
    COUNT(DISTINCT match_id)                                    AS matches,
    COUNT(DISTINCT CONCAT(match_id, '-', over_num))             AS overs_bowled,
    ROUND(AVG(required_rr), 2)                                  AS baseline,
    ROUND(SUM(bowler_runs_this_over) /
          COUNT(DISTINCT CONCAT(match_id, '-', over_num)), 2)   AS bowler_economy,
    ROUND(AVG(over_impact), 2)                                  AS impact
FROM (
    SELECT DISTINCT
        match_id, bowler, FLOOR(`over`) AS over_num, innings,
        pitch_surface_type, required_rr,
        bowler_runs_this_over, over_impact
    FROM deliveries
    WHERE innings = 2
) d
GROUP BY bowler, innings, pitch_surface_type,
    CASE
        WHEN over_num BETWEEN 0 AND 5  THEN 'Powerplay'
        WHEN over_num BETWEEN 6 AND 14 THEN 'Middle'
        WHEN over_num BETWEEN 15 AND 19 THEN 'Death'
    END

ORDER BY bowler, innings, pitch_surface_type, phase;


-- ------------------------------------------------------------
-- SECTION 11: USEFUL ANALYSIS QUERIES
-- Run these individually to explore the data
-- ------------------------------------------------------------

-- Best bowlers overall (min 15 overs, at least 1 wicket)
SELECT
    bowler, total_matches, total_overs, total_wickets,
    economy_impact, wicket_impact_per_over,
    combined_z_score AS total_impact_score
FROM bowler_final_impact_scaled
ORDER BY combined_z_score DESC;

-- Best death bowlers across all pitches
SELECT * FROM bowler_phase_impact
WHERE phase = 'Death'
ORDER BY innings, impact DESC;

-- Best powerplay bowlers across all pitches
SELECT * FROM bowler_phase_impact
WHERE phase = 'Powerplay'
ORDER BY innings, impact DESC;

-- Bowler performance by pitch surface type
SELECT * FROM bowler_pitch_phase_impact
WHERE bowler = 'Rashid Khan'
ORDER BY innings, pitch_surface_type, phase;

-- Check for batter name mismatches between deliveries and batter_averages
SELECT DISTINCT d.player_dismissed
FROM deliveries d
LEFT JOIN batter_averages b ON d.player_dismissed = b.Player
WHERE d.player_dismissed IS NOT NULL
  AND d.wicket_type IN ('caught', 'bowled', 'lbw', 'stumped')
  AND b.Player IS NULL
ORDER BY d.player_dismissed;

-- Verify venue to pitch type mapping
SELECT DISTINCT venue, pitch_surface_type
FROM deliveries
ORDER BY pitch_surface_type;

-- Bowlers positive in both innings with more than 5 matches each
-- (Run in Python for cleaner output)
-- SELECT f.bowler, f.avg_economy_diff, s.avg_over_impact
-- FROM bowler_economy_impact_first_innings f
-- JOIN bowler_economy_impact_second_innings s ON f.bowler = s.bowler
-- WHERE f.matches > 5 AND s.matches > 5
-- AND f.avg_economy_diff > 0 AND s.avg_over_impact > 0
-- ORDER BY f.avg_economy_diff + s.avg_over_impact DESC;