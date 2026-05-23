-- =============================================================================
-- URBAN RULES ANALYSIS QUERIES
-- Database: citydb_v5 (3DCityDB v5, EPSG:3879 - Helsinki)
-- =============================================================================
-- This file contains spatial queries to check urban planning rules against
-- CityGML buildings stored in the 3D City Database.
--
-- NOTE: Rules 1, 2, and 3 require parcel/cadastral data that is not present
-- in this dataset (only building geometry is available). The queries use
-- building envelopes as proxies and include notes on how to extend them
-- when parcel data is available.
-- =============================================================================

SET search_path TO citydb, public;

-- =============================================================================
-- HELPER VIEW: Building footprints with height statistics
-- =============================================================================
CREATE OR REPLACE VIEW building_footprints AS
SELECT
    b.id                                             AS building_id,
    b.objectid                                       AS building_gml_id,
    ST_ZMin(b.envelope)                              AS ground_elevation,
    ST_ZMax(b.envelope)                              AS roof_elevation,
    ST_ZMax(b.envelope) - ST_ZMin(b.envelope)        AS building_height,
    ST_Force2D(b.envelope)                           AS bounding_box_2d,
    gs_geom.geometry                                 AS footprint_3d,
    ST_Force2D(gs_geom.geometry)                     AS footprint_2d,
    ST_Area(ST_Force2D(gs_geom.geometry))            AS footprint_area
FROM feature b
JOIN objectclass oc_b ON b.objectclass_id = oc_b.id AND oc_b.classname = 'Building'
JOIN property p_bound ON p_bound.feature_id = b.id AND p_bound.name = 'boundary'
JOIN feature gs      ON gs.id = p_bound.val_feature_id
JOIN objectclass oc_gs ON gs.objectclass_id = oc_gs.id AND oc_gs.classname = 'GroundSurface'
JOIN property p_gs   ON p_gs.feature_id = gs.id AND p_gs.val_geometry_id IS NOT NULL
JOIN geometry_data gs_geom ON gs_geom.id = p_gs.val_geometry_id;


-- =============================================================================
-- OVERVIEW: Dataset summary
-- =============================================================================
SELECT
    COUNT(*)                                AS total_buildings,
    ROUND(MIN(building_height)::numeric, 2) AS min_height_m,
    ROUND(MAX(building_height)::numeric, 2) AS max_height_m,
    ROUND(AVG(building_height)::numeric, 2) AS avg_height_m,
    ROUND(MIN(footprint_area)::numeric, 2)  AS min_footprint_m2,
    ROUND(MAX(footprint_area)::numeric, 2)  AS max_footprint_m2,
    ROUND(AVG(footprint_area)::numeric, 2)  AS avg_footprint_m2
FROM building_footprints;


-- =============================================================================
-- RULE 1: Minimum Setback
-- "Every building must maintain a minimum setback of 3 meters from the side
--  property lines and 5 meters from the front street line."
--
-- Without parcel data, we approximate by checking minimum distances between
-- adjacent buildings. Buildings closer than 6m (2 × 3m side setback) to
-- each other are flagged as potential violations.
-- =============================================================================

-- Rule 1a: Pairs of buildings that are likely too close (< 6m apart)
-- (approximation without parcel data)
SELECT
    a.building_gml_id  AS building_a,
    b.building_gml_id  AS building_b,
    ROUND(ST_Distance(a.footprint_2d, b.footprint_2d)::numeric, 2) AS distance_meters,
    CASE
        WHEN ST_Distance(a.footprint_2d, b.footprint_2d) < 3
            THEN 'CRITICAL: Less than 3m apart'
        WHEN ST_Distance(a.footprint_2d, b.footprint_2d) < 6
            THEN 'WARNING: May violate combined side setback (< 6m)'
        ELSE 'OK'
    END AS setback_status
FROM building_footprints a
JOIN building_footprints b ON b.building_id > a.building_id
WHERE ST_DWithin(a.footprint_2d, b.footprint_2d, 6)
ORDER BY distance_meters;


-- Rule 1b: Summary count
SELECT
    COUNT(*) FILTER (WHERE ST_Distance(a.footprint_2d, b.footprint_2d) < 3)  AS critical_pairs,
    COUNT(*) FILTER (WHERE ST_Distance(a.footprint_2d, b.footprint_2d) < 6)  AS warning_pairs
FROM building_footprints a
JOIN building_footprints b ON b.building_id > a.building_id
WHERE ST_DWithin(a.footprint_2d, b.footprint_2d, 6);


-- =============================================================================
-- RULE 2: Height / Street Width Ratio
-- "A building's height cannot exceed 1.5 times the width of the street it
--  faces, unless it steps back from the street as it goes higher."
--
-- Without street network data, we use the width of the building's own
-- bounding box as a proxy for the facing dimension, and flag buildings
-- where height > 1.5 × min_side_length as potentially problematic.
-- =============================================================================


-- Height
--   ▲
--   │          / ◄───────────────── Invisible Sky Exposure Plane
--   │         /                    (Diagonal Line)
--   │        /       ┌──────────┐
-- 60m─      /        │          │
--   │      /         │          │ ◄──── Upper floors must STEP BACK
--   │     /          │          │       to stay under the diagonal line
--   │    /     ┌─────┘          │
-- 30m─  /      │                │ ◄──── Front wall can go straight up
--   │  /       │                │       until it hits the 1.5x street limit
--   │ /        │                │
--   │/_________│________________│_______► Distance
--    ◄────────► ◄──────────────►
--      Street     Building Lot
--      Width

-- Rule 2: Buildings where height exceeds 1.5× their narrowest dimension
WITH building_dims AS (
    SELECT
        building_gml_id,
        building_height,
        ROUND(building_height::numeric, 2)                               AS height_m,
        ROUND((ST_XMax(bounding_box_2d) - ST_XMin(bounding_box_2d))::numeric, 2) AS width_east_west,
        ROUND((ST_YMax(bounding_box_2d) - ST_YMin(bounding_box_2d))::numeric, 2) AS width_north_south,
        LEAST(
            ST_XMax(bounding_box_2d) - ST_XMin(bounding_box_2d),
            ST_YMax(bounding_box_2d) - ST_YMin(bounding_box_2d)
        )                                                                AS min_face_width
    FROM building_footprints
)
SELECT
    building_gml_id,
    height_m,
    width_east_west,
    width_north_south,
    ROUND(min_face_width::numeric, 2)                   AS min_face_width_m,
    ROUND((building_height / NULLIF(min_face_width, 0))::numeric, 3) AS height_to_width_ratio,
    CASE
        WHEN building_height > 1.5 * min_face_width
            THEN 'VIOLATION: Height > 1.5x street-facing width'
        WHEN building_height > 1.2 * min_face_width
            THEN 'WARNING: Height approaching 1.5x limit'
        ELSE 'OK'
    END AS rule_2_status
FROM building_dims
ORDER BY height_to_width_ratio DESC NULLS LAST;


-- Rule 2: Summary
WITH building_dims AS (
    SELECT
        building_height,
        LEAST(
            ST_XMax(bounding_box_2d) - ST_XMin(bounding_box_2d),
            ST_YMax(bounding_box_2d) - ST_YMin(bounding_box_2d)
        ) AS min_face_width
    FROM building_footprints
)
SELECT
    COUNT(*) FILTER (WHERE building_height > 1.5 * min_face_width) AS rule2_violations,
    COUNT(*) FILTER (WHERE building_height > 1.2 * min_face_width
                       AND building_height <= 1.5 * min_face_width) AS rule2_warnings,
    COUNT(*) FILTER (WHERE building_height <= 1.2 * min_face_width) AS rule2_compliant
FROM building_dims;


-- =============================================================================
-- RULE 3: Ground Coverage / Building-to-Parcel Ratio
-- "The building's ground footprint cannot occupy more than 60% of the total
--  parcel area. The remaining 40% must be open space or green area."
--
-- Without parcel polygons, we compute the ratio of footprint area to the
-- area of the convex hull of each building cluster (approximated parcels).
-- =============================================================================

-- Rule 3a: Coverage ratio using bounding box as parcel proxy
SELECT
    building_gml_id,
    ROUND(footprint_area::numeric, 2)                                        AS footprint_area_m2,
    ROUND(ST_Area(bounding_box_2d)::numeric, 2)                              AS bbox_area_m2,
    ROUND((footprint_area / NULLIF(ST_Area(bounding_box_2d), 0) * 100)::numeric, 1) AS coverage_pct,
    CASE
        WHEN footprint_area / NULLIF(ST_Area(bounding_box_2d), 0) > 0.60
            THEN 'VIOLATION: Footprint > 60% of parcel (bbox proxy)'
        WHEN footprint_area / NULLIF(ST_Area(bounding_box_2d), 0) > 0.50
            THEN 'WARNING: Coverage between 50-60%'
        ELSE 'OK'
    END AS rule_3_status
FROM building_footprints
ORDER BY coverage_pct DESC NULLS LAST;


-- Rule 3b: Summary
SELECT
    COUNT(*) FILTER (WHERE footprint_area / NULLIF(ST_Area(bounding_box_2d), 0) > 0.60) AS rule3_violations,
    COUNT(*) FILTER (WHERE footprint_area / NULLIF(ST_Area(bounding_box_2d), 0) BETWEEN 0.50 AND 0.60) AS rule3_warnings,
    COUNT(*) FILTER (WHERE footprint_area / NULLIF(ST_Area(bounding_box_2d), 0) <= 0.50) AS rule3_compliant
FROM building_footprints;


-- =============================================================================
-- RULE 4: Minimum Building Height
-- "Buildings must be at least 3 meters in height (not sheds or temporary
--  structures)."
-- =============================================================================

SELECT
    building_gml_id,
    ROUND(building_height::numeric, 2) AS height_m,
    CASE
        WHEN building_height < 3  THEN 'VIOLATION: Height < 3m'
        WHEN building_height < 5  THEN 'WARNING: Very low building (3-5m)'
        ELSE 'OK'
    END AS rule_4_status
FROM building_footprints
ORDER BY height_m;


-- Rule 4: Summary
SELECT
    COUNT(*) FILTER (WHERE building_height < 3) AS rule4_violations,
    COUNT(*) FILTER (WHERE building_height BETWEEN 3 AND 5) AS rule4_warnings,
    COUNT(*) FILTER (WHERE building_height > 5) AS rule4_compliant
FROM building_footprints;


-- =============================================================================
-- RULE 5: Maximum Building Height
-- "No building shall exceed 50 meters in height without a special permit."
-- =============================================================================

SELECT
    building_gml_id,
    ROUND(building_height::numeric, 2) AS height_m,
    CASE
        WHEN building_height > 50 THEN 'VIOLATION: Height > 50m (requires special permit)'
        WHEN building_height > 40 THEN 'WARNING: Height 40-50m (approaching limit)'
        ELSE 'OK'
    END AS rule_5_status
FROM building_footprints
WHERE building_height > 30
ORDER BY height_m DESC;


-- Rule 5: Summary
SELECT
    COUNT(*) FILTER (WHERE building_height > 50) AS rule5_violations,
    COUNT(*) FILTER (WHERE building_height BETWEEN 40 AND 50) AS rule5_warnings,
    COUNT(*) FILTER (WHERE building_height <= 40) AS rule5_compliant
FROM building_footprints;


-- =============================================================================
-- RULE 6: Building Density / Floor Area Ratio (FAR)
-- "The total floor area of a building (estimated as footprint × floors)
--  cannot exceed 3 times the parcel area (FAR ≤ 3.0)."
-- Floors are estimated as ROUND(height / 3.2).
-- =============================================================================

SELECT
    building_gml_id,
    ROUND(building_height::numeric, 2)                         AS height_m,
    ROUND(footprint_area::numeric, 2)                          AS footprint_m2,
    GREATEST(1, ROUND(building_height / 3.2)::int)             AS estimated_floors,
    ROUND((footprint_area * GREATEST(1, ROUND(building_height / 3.2)))::numeric, 2) AS estimated_total_floor_area_m2,
    ROUND((footprint_area * GREATEST(1, ROUND(building_height / 3.2)) 
        / NULLIF(ST_Area(bounding_box_2d), 0))::numeric, 3)    AS far_ratio,
    CASE
        WHEN (footprint_area * GREATEST(1, ROUND(building_height / 3.2)) 
            / NULLIF(ST_Area(bounding_box_2d), 0)) > 3.0
            THEN 'VIOLATION: FAR > 3.0'
        WHEN (footprint_area * GREATEST(1, ROUND(building_height / 3.2)) 
            / NULLIF(ST_Area(bounding_box_2d), 0)) > 2.5
            THEN 'WARNING: FAR 2.5-3.0'
        ELSE 'OK'
    END AS rule_6_status
FROM building_footprints
ORDER BY far_ratio DESC NULLS LAST;


-- =============================================================================
-- COMBINED COMPLIANCE REPORT: All rules per building
-- =============================================================================

WITH dims AS (
    SELECT
        building_id,
        building_gml_id,
        building_height,
        footprint_area,
        bounding_box_2d,
        LEAST(
            ST_XMax(bounding_box_2d) - ST_XMin(bounding_box_2d),
            ST_YMax(bounding_box_2d) - ST_YMin(bounding_box_2d)
        ) AS min_face_width,
        ST_Area(bounding_box_2d) AS parcel_proxy_area
    FROM building_footprints
),
nearest_neighbor AS (
    SELECT
        a.building_id,
        MIN(ST_Distance(a.footprint_2d, b.footprint_2d)) AS min_neighbor_dist
    FROM building_footprints a
    JOIN building_footprints b ON b.building_id != a.building_id
    GROUP BY a.building_id
)
SELECT
    d.building_gml_id,
    ROUND(d.building_height::numeric, 2)                              AS height_m,
    ROUND(d.footprint_area::numeric, 2)                               AS footprint_m2,
    ROUND(n.min_neighbor_dist::numeric, 2)                            AS nearest_building_m,
    -- Rule 1: Setback
    CASE WHEN n.min_neighbor_dist < 3  THEN 'FAIL' 
         WHEN n.min_neighbor_dist < 6  THEN 'WARN' ELSE 'OK' END      AS rule1_setback,
    -- Rule 2: Height/width ratio
    CASE WHEN d.building_height > 1.5 * d.min_face_width THEN 'FAIL'
         WHEN d.building_height > 1.2 * d.min_face_width THEN 'WARN' ELSE 'OK' END AS rule2_height_ratio,
    -- Rule 3: Coverage
    CASE WHEN d.footprint_area / NULLIF(d.parcel_proxy_area, 0) > 0.60 THEN 'FAIL'
         WHEN d.footprint_area / NULLIF(d.parcel_proxy_area, 0) > 0.50 THEN 'WARN' ELSE 'OK' END AS rule3_coverage,
    -- Rule 4: Min height
    CASE WHEN d.building_height < 3 THEN 'FAIL'
         WHEN d.building_height < 5 THEN 'WARN' ELSE 'OK' END         AS rule4_min_height,
    -- Rule 5: Max height
    CASE WHEN d.building_height > 50 THEN 'FAIL'
         WHEN d.building_height > 40 THEN 'WARN' ELSE 'OK' END        AS rule5_max_height
FROM dims d
JOIN nearest_neighbor n ON n.building_id = d.building_id
ORDER BY
    (CASE WHEN n.min_neighbor_dist < 3  THEN 2 WHEN n.min_neighbor_dist < 6  THEN 1 ELSE 0 END +
     CASE WHEN d.building_height > 1.5 * d.min_face_width THEN 2 WHEN d.building_height > 1.2 * d.min_face_width THEN 1 ELSE 0 END +
     CASE WHEN d.footprint_area / NULLIF(d.parcel_proxy_area, 0) > 0.60 THEN 2 WHEN d.footprint_area / NULLIF(d.parcel_proxy_area, 0) > 0.50 THEN 1 ELSE 0 END +
     CASE WHEN d.building_height < 3 THEN 2 WHEN d.building_height < 5 THEN 1 ELSE 0 END +
     CASE WHEN d.building_height > 50 THEN 2 WHEN d.building_height > 40 THEN 1 ELSE 0 END
    ) DESC;