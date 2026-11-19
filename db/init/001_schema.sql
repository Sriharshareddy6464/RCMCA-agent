CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

DO $$ BEGIN
    CREATE TYPE hazard_category AS ENUM (
        'pothole', 'waterlogging', 'damaged_surface', 'open_manhole',
        'broken_divider', 'other'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE hazard_status AS ENUM (
        'community_pending', 'verified_ghmc', 'active_hazard', 'resolved'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE verification_vote_type AS ENUM ('CONFIRM', 'RESOLVED');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS road_issues (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    category hazard_category NOT NULL,
    severity SMALLINT NOT NULL CHECK (severity BETWEEN 1 AND 5),
    confidence_score DOUBLE PRECISION NOT NULL DEFAULT 1.0,
    report_count INTEGER NOT NULL DEFAULT 1 CHECK (report_count >= 1),
    description TEXT NOT NULL,
    evidence_image_url TEXT,
    location GEOMETRY(Point, 4326) NOT NULL,
    source VARCHAR(50) NOT NULL,
    external_ticket_id VARCHAR(100),
    status hazard_status NOT NULL DEFAULT 'community_pending',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_road_issues_location
    ON road_issues USING GIST (location);
CREATE INDEX IF NOT EXISTS idx_road_issues_status
    ON road_issues (status);
CREATE INDEX IF NOT EXISTS idx_road_issues_category_status
    ON road_issues (category, status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_road_issues_external_ticket
    ON road_issues (source, external_ticket_id)
    WHERE external_ticket_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS verification_votes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    issue_id UUID NOT NULL REFERENCES road_issues(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    vote_type verification_vote_type NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (issue_id, user_id)
);

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

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_road_issues_updated_at ON road_issues;
CREATE TRIGGER trg_road_issues_updated_at
    BEFORE UPDATE ON road_issues
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
