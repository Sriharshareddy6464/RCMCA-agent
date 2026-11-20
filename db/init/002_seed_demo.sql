-- Demo road reports use recognizable Hyderabad corridors. They are illustrative
-- application seed records, not verified or official GHMC complaints.
DELETE FROM road_issues
WHERE source = 'demo_seed'
  AND external_ticket_id LIKE 'DEMO-%';

INSERT INTO road_issues (
    category, severity, confidence_score, report_count, description,
    location, source, external_ticket_id, status, created_at
)
VALUES
    ('pothole', 4, 1.0, 2,
     'Deep potholes are reported on ISB Road near Gachibowli; two-wheelers are swerving around the damaged patches.',
     ST_SetSRID(ST_MakePoint(78.3472, 17.4405), 4326), 'demo_seed', 'DEMO-HYD-001', 'active_hazard', NOW() - INTERVAL '9 days'),
    ('waterlogging', 3, 1.0, 2,
     'Water is reported to collect on the Durgam Cheruvu Cable Bridge approach after rain, slowing vehicles entering the bridge.',
     ST_SetSRID(ST_MakePoint(78.3910, 17.4320), 4326), 'demo_seed', 'DEMO-HYD-002', 'community_pending', NOW() - INTERVAL '5 days'),
    ('damaged_surface', 3, 1.0, 1,
     'Uneven and broken pavement is reported near Kukatpally Y-Junction, where traffic merges from the service road.',
     ST_SetSRID(ST_MakePoint(78.3990, 17.4935), 4326), 'demo_seed', 'DEMO-HYD-003', 'active_hazard', NOW() - INTERVAL '12 days'),
    ('pothole', 3, 1.0, 2,
     'A row of potholes is reported along the Tarnaka Metro stretch, including the lane beside the station access.',
     ST_SetSRID(ST_MakePoint(78.5325, 17.4275), 4326), 'demo_seed', 'DEMO-HYD-004', 'active_hazard', NOW() - INTERVAL '8 days'),
    ('damaged_surface', 2, 1.0, 1,
     'A rough, patched road surface is reported on Secunderabad Station Road near the station forecourt and bus movement.',
     ST_SetSRID(ST_MakePoint(78.5010, 17.4340), 4326), 'demo_seed', 'DEMO-HYD-005', 'community_pending', NOW() - INTERVAL '6 days'),
    ('waterlogging', 4, 1.0, 3,
     'Standing wastewater is reported on the Saidabad-Chanchalguda corridor after rain, narrowing the usable carriageway.',
     ST_SetSRID(ST_MakePoint(78.5050, 17.3630), 4326), 'demo_seed', 'DEMO-HYD-006', 'active_hazard', NOW() - INTERVAL '4 days')
ON CONFLICT (source, external_ticket_id) WHERE external_ticket_id IS NOT NULL
DO UPDATE SET
    category = EXCLUDED.category,
    severity = EXCLUDED.severity,
    confidence_score = EXCLUDED.confidence_score,
    report_count = EXCLUDED.report_count,
    description = EXCLUDED.description,
    location = EXCLUDED.location,
    status = EXCLUDED.status,
    updated_at = NOW();
