CREATE TABLE IF NOT EXISTS vision_assessments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    issue_id UUID NOT NULL REFERENCES road_issues(id) ON DELETE CASCADE,
    status VARCHAR(16) NOT NULL CHECK (status IN ('pending', 'complete', 'failed')),
    model_name TEXT,
    severity_estimate SMALLINT CHECK (severity_estimate BETWEEN 1 AND 5),
    detections JSONB,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_vision_assessments_issue_created
    ON vision_assessments (issue_id, created_at DESC);
