from __future__ import annotations

from datetime import datetime
from typing import Any, Literal
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
    user_id: UUID
    vote_type: VoteType


class VerifyIssueByIdRequest(VerifyIssueRequest):
    issue_id: UUID


class VerifyIssueResponse(BaseModel):
    issue_id: UUID
    confidence_score: float
    status: HazardStatus
    vote_recorded: bool = True


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
