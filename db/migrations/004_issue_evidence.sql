CREATE TABLE IF NOT EXISTS issue_evidence (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    issue_id UUID NOT NULL REFERENCES road_issues(id) ON DELETE CASCADE,
    image_url TEXT NOT NULL,
    location GEOMETRY(Point, 4326) NOT NULL,
    accuracy_m DOUBLE PRECISION CHECK (accuracy_m IS NULL OR accuracy_m >= 0),
    heading_degrees DOUBLE PRECISION CHECK (heading_degrees IS NULL OR (heading_degrees >= 0 AND heading_degrees < 360)),
    captured_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_issue_evidence_issue ON issue_evidence (issue_id, created_at);
