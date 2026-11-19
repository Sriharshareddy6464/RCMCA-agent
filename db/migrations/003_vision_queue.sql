ALTER TABLE vision_assessments
    ADD COLUMN IF NOT EXISTS image_data BYTEA;

ALTER TABLE vision_assessments
    DROP CONSTRAINT IF EXISTS vision_assessments_status_check;
ALTER TABLE vision_assessments
    ADD CONSTRAINT vision_assessments_status_check
    CHECK (status IN ('pending', 'processing', 'complete', 'failed'));

CREATE INDEX IF NOT EXISTS idx_vision_assessments_pending
    ON vision_assessments (created_at)
    WHERE status = 'pending';
