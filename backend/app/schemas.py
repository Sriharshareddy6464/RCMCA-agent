from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

HazardCategory = Literal[
    "pothole", "waterlogging", "damaged_surface", "open_manhole",
    "broken_divider", "other",
]
HazardStatus = Literal[
    "community_pending", "verified_ghmc", "active_hazard", "resolved",
]
VoteType = Literal["CONFIRM", "RESOLVED"]
StatusColor = Literal["GREEN", "BLUE", "YELLOW", "ORANGE", "RED"]
ImageUrl = Annotated[str, Field(min_length=1, max_length=2048)]


class IssueReportRequest(BaseModel):
    category: HazardCategory
    description: str = Field(min_length=8, max_length=2000)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    severity: int = Field(default=3, ge=1, le=5)
    evidence_image_url: str | None = Field(default=None, max_length=2048)
    capture_accuracy_m: float | None = Field(default=None, ge=0, le=10000)
    capture_heading_degrees: float | None = Field(default=None, ge=0, lt=360)
    captured_at: datetime | None = None
    # 3-layer survey: (1) still present, (2) condition 1..5, (3) impact MCQ.
    still_present: bool = True
    condition_score: int | None = Field(default=None, ge=1, le=5)
    impact_mcq: str | None = Field(default=None, min_length=1, max_length=64)
    image_urls: list[ImageUrl] = Field(default_factory=list, max_length=4)

    @model_validator(mode="after")
    def survey_is_consistent(self):
        if not self.still_present:
            raise ValueError("a new report must have still_present=true")
        if self.condition_score is not None:
            self.severity = self.condition_score
        if self.impact_mcq is not None:
            self.impact_mcq = self.impact_mcq.strip() or None
        return self


class EvidenceImage(BaseModel):
    id: UUID
    image_url: str
    latitude: float
    longitude: float
    accuracy_m: float | None
    heading_degrees: float | None
    captured_at: datetime
    created_at: datetime


class IssueResponse(BaseModel):
    id: UUID
    category: HazardCategory
    severity: int
    confidence_score: float
    report_count: int
    description: str
    evidence_image_url: str | None
    latitude: float
    longitude: float
    source: str
    external_ticket_id: str | None
    status: HazardStatus
    created_at: datetime
    updated_at: datetime
    evidence: list[EvidenceImage] = Field(default_factory=list)
    corporation: str | None = None
    zone: str | None = None
    ward_no: int | None = None
    ward_name: str | None = None
    authority_designation: str | None = None
    authority_email: str | None = None
    status_color: StatusColor | None = None
    impact_mcq: str | None = None
    image_urls: list[str] = Field(default_factory=list)


class IssueReportResponse(BaseModel):
    issue: IssueResponse
    deduplicated: bool
    deduplication_radius_m: int = 25


class IssueViewportRequest(BaseModel):
    south: float = Field(ge=-90, le=90)
    west: float = Field(ge=-180, le=180)
    north: float = Field(ge=-90, le=90)
    east: float = Field(ge=-180, le=180)
    limit: int = Field(default=500, ge=1, le=1000)

    @model_validator(mode="after")
    def valid_bounds(self):
        if self.south >= self.north:
            raise ValueError("south must be less than north")
        if self.west >= self.east:
            raise ValueError("west must be less than east; split antimeridian viewports")
        return self


class VerifyIssueRequest(BaseModel):
    """3-layer survey vote.

    New clients send still_present + condition_score + impact_mcq. Legacy clients
    that only send vote_type (CONFIRM / RESOLVED) are still accepted.
    """

    user_id: UUID
    vote_type: VoteType | None = None
    still_present: bool | None = None
    condition_score: int | None = Field(default=None, ge=1, le=5)
    impact_mcq: str | None = Field(default=None, min_length=1, max_length=64)

    @model_validator(mode="after")
    def normalise_survey(self):
        if self.vote_type is None and self.still_present is None:
            raise ValueError("provide still_present (or legacy vote_type)")
        explicit_survey = "still_present" in self.model_fields_set
        if self.still_present is None:
            self.still_present = self.vote_type == "CONFIRM"
        expected = "CONFIRM" if self.still_present else "RESOLVED"
        if self.vote_type is not None and self.vote_type != expected:
            raise ValueError("vote_type conflicts with still_present")
        self.vote_type = expected
        if self.still_present:
            if self.impact_mcq is not None:
                self.impact_mcq = self.impact_mcq.strip() or None
            if explicit_survey and (self.condition_score is None or self.impact_mcq is None):
                raise ValueError(
                    "condition_score and impact_mcq are required when still_present is true"
                )
        else:
            self.condition_score = None
            self.impact_mcq = None
        return self


class VerifyIssueByIdRequest(VerifyIssueRequest):
    issue_id: UUID


class VerifyIssueResponse(BaseModel):
    issue_id: UUID
    confidence_score: float
    status: HazardStatus
    vote_recorded: bool = True
    still_present: bool | None = None
    condition_score: int | None = None
    impact_mcq: str | None = None
    severity: int | None = None
    status_color: StatusColor | None = None


class Coordinate(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class RoutePlanRequest(BaseModel):
    origin: Coordinate
    destination: Coordinate


class RouteHazard(BaseModel):
    id: UUID
    category: HazardCategory
    severity: int
    status: HazardStatus
    description: str
    distance_from_route_m: float
    latitude: float
    longitude: float


class RoutePlanResponse(BaseModel):
    geometry: dict[str, Any]
    distance_m: float
    duration_s: float
    avoided_severe_hazards: bool
    alternatives_considered: int
    hazards: list[RouteHazard]


class IssueAssessmentRequest(BaseModel):
    description: str = Field(min_length=8, max_length=4000)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    near_sensitive_site: bool = False
    language: Literal["en", "te", "hi"] = "en"

    @model_validator(mode="after")
    def coordinates_are_complete(self):
        if (self.latitude is None) != (self.longitude is None):
            raise ValueError("latitude and longitude must be supplied together")
        return self


class VisionAssessmentResponse(BaseModel):
    assessment_id: UUID
    issue_id: UUID
    status: Literal["pending"]
    message: str
