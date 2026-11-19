-- Synthetic local demo data; these are not real GHMC records.
SELECT setseed(0.420);

INSERT INTO road_issues (
    category, severity, confidence_score, report_count, description,
    location, source, external_ticket_id, status, created_at
)
SELECT
    (ARRAY['pothole', 'waterlogging', 'damaged_surface', 'open_manhole', 'broken_divider']
        )[1 + (n % 5)]::hazard_category,
    1 + (n % 5),
    1.0,
    1 + (n % 8),
    'Synthetic demo road issue #' || lpad(n::text, 3, '0'),
    ST_SetSRID(ST_MakePoint(
        CASE n % 3
            WHEN 0 THEN 78.4483 + (random() - 0.5) * 0.020
            WHEN 1 THEN 78.3764 + (random() - 0.5) * 0.020
            ELSE 78.4668 + (random() - 0.5) * 0.020
        END,
        CASE n % 3
            WHEN 0 THEN 17.4126 + (random() - 0.5) * 0.020
            WHEN 1 THEN 17.4435 + (random() - 0.5) * 0.020
            ELSE 17.4447 + (random() - 0.5) * 0.020
        END
    ), 4326),
    'demo_seed',
    'DEMO-' || lpad(n::text, 3, '0'),
    CASE WHEN n % 7 = 0 THEN 'resolved'::hazard_status
         WHEN n % 3 = 0 THEN 'active_hazard'::hazard_status
         ELSE 'community_pending'::hazard_status END,
    NOW() - ((n % 180)::text || ' days')::interval
FROM generate_series(1, 100) AS n
ON CONFLICT (source, external_ticket_id) WHERE external_ticket_id IS NOT NULL
DO NOTHING;
