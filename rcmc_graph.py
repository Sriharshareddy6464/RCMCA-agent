"""LangGraph workflow for turning a citizen report into a triaged road issue."""

from __future__ import annotations

import os
import json
import asyncio
import logging
import re
from typing import Any, Awaitable, Callable, Literal, TypedDict

from langchain_openai import ChatOpenAI
from langgraph.graph import END, START, StateGraph
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)

HazardCategory = Literal[
    "pothole",
    "waterlogging",
    "damaged_surface",
    "open_manhole",
    "broken_divider",
    "other",
]


class IssueFacts(BaseModel):
    """Fields normalized from a resident's free-text report."""

    category: HazardCategory
    severity: int = Field(ge=1, le=5, description="Estimated road hazard severity")
    concise_description: str = Field(min_length=8, max_length=400)
    uncertainty: str = Field(
        description="Important missing or uncertain details; use 'none' when clear"
    )


class ComplaintDraft(BaseModel):
    subject: str = Field(min_length=8, max_length=120)
    body: str = Field(min_length=40, max_length=1500)


class IssueState(TypedDict, total=False):
    description: str
    latitude: float | None
    longitude: float | None
    near_sensitive_site: bool
    language: Literal["en", "te", "hi"]
    facts: IssueFacts
    priority_score: int
    dispatch_tier: Literal["HIGH", "MEDIUM", "LOW"]
    action_required: str
    complaint_subject: str
    complaint_draft: str


class ChatIntent(BaseModel):
    """Structured intent parsed from a conversational navigation/issue request."""

    action: Literal["route", "issue", "other"]
    origin: str | None = Field(
        default=None,
        description="Origin place name; use 'current location' when the user says here or my location",
    )
    destination: str | None = Field(default=None, description="Destination place name")
    issue_id: str | None = Field(default=None, description="UUID of the referenced road issue, if present")
    issue_query: str | None = Field(
        default=None,
        description="Short identifying phrase with the issue category and locality, when available",
    )
    language: Literal["en", "te", "hi"] = "en"


class ChatState(TypedDict, total=False):
    message: str
    user_lat: float | None
    user_lon: float | None
    intent: ChatIntent
    route_audit: dict[str, Any]
    issue: dict[str, Any]
    email_draft: ComplaintDraft
    answer: str
    llm_fallback: bool


def deterministic_chat_intent(message: str, user_lat=None, user_lon=None) -> ChatIntent:
    """Extract route or issue intent without calling an LLM."""
    text = " ".join(message.strip().split())
    folded = text.casefold()
    language: Literal["en", "te", "hi"] = "en"
    if re.search(r"[\u0c00-\u0c7f]", text):
        language = "te"
    elif re.search(r"[\u0900-\u097f]", text):
        language = "hi"

    issue_match = re.search(
        r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
        text,
    )
    pair = re.search(
        r"\bfrom\s+(?P<origin>.+?)\s+to\s+(?P<destination>.+?)(?=$|[?.!,;])",
        text,
        flags=re.IGNORECASE,
    )
    if pair is None:
        pair = re.search(
            r"\bbetween\s+(?P<origin>.+?)\s+and\s+(?P<destination>.+?)(?=$|[?.!,;])",
            text,
            flags=re.IGNORECASE,
        )
    if pair is None:
        pair = re.search(
            r"(?P<origin>.+?)\s+से\s+(?P<destination>.+?)\s+तक(?=$|[?.!,;])",
            text,
        )
    if pair is None:
        pair = re.search(
            r"(?P<origin>.+?)\s+(?:నుంచి|నుండి)\s+(?P<destination>.+?)\s+వరకు(?=$|[?.!,;])",
            text,
        )

    route_request = bool(
        pair
        or re.search(
            r"\b(route|navigate|navigation|travel|drive|driving|directions|commute|destination|go to|get to|"
            r"रास्ता|मार्ग|सड़क|जाना|जाऊं|जाएँ|"
            r"మార్గం|రోడ్డు|వెళ్లాలి|వెళ్ళాలి|వెళ్లడానికి|వెళ్ళడానికి)\b",
            folded,
        )
    )
    if route_request:
        origin = pair.group("origin").strip() if pair else None
        destination = pair.group("destination").strip() if pair else None
        if pair is None:
            single_destination = re.search(
                r"\b(?:plan\s+(?:a\s+)?route|route|navigate|navigation|travel|drive|directions|go|get|take\s+me)"
                r"\s+(?:me\s+)?(?:to|towards)\s+(?P<destination>.+?)(?=$|[?.!,;])",
                text,
                flags=re.IGNORECASE,
            )
            if single_destination:
                destination = single_destination.group("destination").strip()
        if destination:
            destination = re.split(
                r"\b(?:are there any|is there any|any issues?|on the way|in the way|"
                r"avoiding|without|via|please|safest route)\b",
                destination,
                maxsplit=1,
                flags=re.IGNORECASE,
            )[0].strip(" .,!?:;")
        if origin and re.fullmatch(
            r"(?:my\s+)?(?:current\s+location|location|here|मेरी\s+लोकेशन|मेरी\s+जगह)",
            origin,
            flags=re.IGNORECASE,
        ):
            origin = "current location"
        elif not origin and user_lat is not None and user_lon is not None:
            origin = "current location"
        return ChatIntent(
            action="route",
            origin=origin or None,
            destination=destination or None,
            issue_id=None,
            issue_query=None,
            language=language,
        )

    issue_request = bool(
        issue_match
        or re.search(
            r"\b(issue|complaint|inspection|inspect|potholes?|waterlog(?:ging)?|"
            r"manholes?|damaged road|road condition|hazard|repair|sewage|cracks?|"
            r"शिकायत|समस्या|गड्ढा|जलभराव|निरीक्षण|सड़क|नाला|"
            r"ఫిర్యాదు|సమస్య|గుంత|నీరు నిల్వ|పరిశీలన|రహదారి|కాలువ)\b",
            folded,
        )
    )
    if issue_request:
        query = re.sub(
            r"\b(?:can you|could you|would you|please|send|draft|write|file|"
            r"submit|raise|make|about|tell me about|what is|what's|status of|"
            r"inspection|inspect|complaint|issue|reported|report|road|near|at|the|"
            r"in|on|for|email|mail)\b",
            " ",
            folded,
            flags=re.IGNORECASE,
        )
        if issue_match:
            query = query.replace(issue_match.group(0).casefold(), " ")
        query = re.sub(r"[^\w\s-]", " ", query)
        query = " ".join(query.split())
        return ChatIntent(
            action="issue",
            issue_id=issue_match.group(0) if issue_match else None,
            issue_query=query or None,
            language=language,
        )

    return ChatIntent(action="other", language=language)


def deterministic_issue_email(issue: dict[str, Any], language: str = "en") -> ComplaintDraft:
    """Create a fact-bound inspection email when the configured LLM is offline."""
    category = str(issue.get("category") or "road issue")
    ward = str(issue.get("ward_name") or "unassigned ward")
    corporation = str(issue.get("corporation") or "municipal corporation not recorded")
    designation = str(issue.get("authority_designation") or "Municipal Road Inspection Team")
    status = str(issue.get("status") or "status not recorded")
    description = str(issue.get("description") or category)
    latitude = issue.get("latitude")
    longitude = issue.get("longitude")
    coordinates = (
        f"{float(latitude):.6f}, {float(longitude):.6f}"
        if latitude is not None and longitude is not None
        else "not recorded in the issue record"
    )
    zone = str(issue.get("zone") or "zone not recorded")
    impact = str(issue.get("impact_mcq") or "commuter impact not recorded")
    subject = f"Road inspection request: {category} - {ward}"[:120]

    if language == "te":
        subject = f"రోడ్డు పరిశీలన అభ్యర్థన: {category} - {ward}"[:120]
        body = (
            f"గౌరవనీయులైన {designation} గారికి,\n\n"
            f"{ward} వార్డులో నమోదైన {category} సమస్య గురించి తెలియజేస్తున్నాను. "
            f"నమోదైన రహదారి పరిస్థితి: {description}\nఖచ్చితమైన coordinates (latitude, longitude): {coordinates}\n"
            f"వార్డు: {ward}; జోన్: {zone}; కార్పొరేషన్: {corporation}\n"
            f"ప్రయాణికులపై నమోదైన ప్రభావం: {impact}\nప్రస్తుత నమోదు స్థితి: {status}\n\n"
            "దయచేసి సౌకర్యమైన సమయంలో సిబ్బందిని పంపి స్థలాన్ని పరిశీలించి, అవసరమైతే తగిన చర్యను పరిగణించగలరు. ధన్యవాదాలు."
        )
    elif language == "hi":
        subject = f"सड़क निरीक्षण अनुरोध: {category} - {ward}"[:120]
        body = (
            f"आदरणीय {designation},\n\n"
            f"{ward} वार्ड में दर्ज {category} समस्या के बारे में सूचित करना चाहता/चाहती हूँ। "
            f"दर्ज सड़क की स्थिति: {description}\nसटीक निर्देशांक (अक्षांश, देशांतर): {coordinates}\n"
            f"वार्ड: {ward}; ज़ोन: {zone}; नगर निगम: {corporation}\n"
            f"आवागमन पर दर्ज प्रभाव: {impact}\nदर्ज वर्तमान स्थिति: {status}\n\n"
            "कृपया सुविधा अनुसार क्षेत्र का निरीक्षण करने के लिए कर्मचारियों को भेजने और आवश्यक कार्रवाई पर विचार करने का कष्ट करें। धन्यवाद।"
        )
    else:
        body = (
            f"Dear {designation},\n\n"
            f"I am writing to bring a recorded {category} road condition to your attention.\n"
            f"Observed/recorded condition: {description}\n"
            f"Exact recorded coordinates (latitude, longitude): {coordinates}\n"
            f"Ward: {ward}; zone: {zone}; corporation: {corporation}\n"
            f"Recorded commuter impact: {impact}\nCurrent recorded status: {status}\n\n"
            "When convenient, could your team please arrange a field inspection and consider any "
            "appropriate action? This request is based on the issue record and does not imply "
            "that an official inspection has already taken place. Thank you for your attention."
        )
    return ComplaintDraft(subject=subject, body=body[:1500])


def _model():
    """Create a local OpenAI-compatible or AWS Bedrock Converse chat client."""
    provider = os.getenv("LLM_PROVIDER", "openai_compatible").strip().lower()
    if provider == "bedrock":
        from langchain_aws import ChatBedrockConverse

        return ChatBedrockConverse(
            model=os.getenv("LLM_MODEL", "qwen.qwen3-32b-v1:0"),
            region_name=os.getenv("AWS_REGION", "ap-south-1"),
            temperature=0,
        )
    return ChatOpenAI(
        base_url=os.getenv("LLM_BASE_URL", "http://localhost:11434/v1"),
        api_key=os.getenv("LLM_API_KEY", "ollama-local"),
        model=os.getenv("LLM_MODEL", "qwen2.5:3b"),
        temperature=0,
    )


def build_issue_graph(chat_model=None):
    """Build the report normalization and deterministic triage workflow."""
    llm = chat_model or _model()
    structured_llm = llm.with_structured_output(IssueFacts)
    structured_draft_llm = llm.with_structured_output(ComplaintDraft)

    def normalize_report(state: IssueState) -> dict:
        result = structured_llm.invoke(
            [
                (
                    "system",
                    "Normalize a citizen's road hazard report. Classify only into the "
                    "allowed category list. Estimate severity from 1 (minor) to 5 "
                    "(immediate danger), based only on the supplied text. Do not invent "
                    "a location, cause, injury, or fact. If details are unclear, state "
                    "that in uncertainty and use a conservative estimate.",
                ),
                ("human", state["description"]),
            ]
        )
        return {"facts": result}

    def prioritize(state: IssueState) -> dict:
        facts = state["facts"]
        # Transparent rules keep operational priority independent of model prose.
        score = facts.severity * 15
        if facts.category in {"open_manhole", "waterlogging", "broken_divider"}:
            score += 10
        if state.get("near_sensitive_site", False):
            score += 20
        score = min(score, 100)

        if score >= 75:
            tier, action = "HIGH", "Immediate crew inspection"
        elif score >= 45:
            tier, action = "MEDIUM", "Schedule maintenance inspection"
        else:
            tier, action = "LOW", "Monitor and include in routine inspection"

        return {
            "priority_score": score,
            "dispatch_tier": tier,
            "action_required": action,
        }

    def draft_complaint(state: IssueState) -> dict:
        facts = state["facts"]
        details = {
            "category": facts.category,
            "severity_estimate": facts.severity,
            "description": facts.concise_description,
            "uncertainty": facts.uncertainty,
            "latitude": state.get("latitude"),
            "longitude": state.get("longitude"),
        }
        draft = structured_draft_llm.invoke(
            [
                (
                    "system",
                    "Write a concise, respectful municipal road-repair complaint using "
                    "only the provided facts. Do not invent a street name, landmark, "
                    "date, injury, or cause. Ask for inspection and appropriate repair. "
                    "Write the subject and body in the requested language: en=English, "
                    "te=Telugu, hi=Hindi. Severity is an estimate; do not present it "
                    "as an official inspection result.",
                ),
                (
                    "human",
                    json.dumps(
                        {"language": state.get("language", "en"), "report": details},
                        ensure_ascii=False,
                    ),
                ),
            ]
        )
        return {"complaint_subject": draft.subject, "complaint_draft": draft.body}

    builder = StateGraph(IssueState)
    builder.add_node("normalize_report", normalize_report)
    builder.add_node("prioritize", prioritize)
    builder.add_node("draft_complaint", draft_complaint)
    builder.add_edge(START, "normalize_report")
    builder.add_edge("normalize_report", "prioritize")
    builder.add_edge("prioritize", "draft_complaint")
    builder.add_edge("draft_complaint", END)
    return builder.compile()


def build_chat_graph(
    route_auditor: Callable[[ChatIntent, ChatState], Awaitable[dict[str, Any]]],
    issue_resolver: Callable[[ChatIntent, ChatState], Awaitable[dict[str, Any]]],
    chat_model=None,
):
    """Build a conversational intent graph with deterministic route/issue tools.

    The model extracts intent and drafts issue correspondence. Route scoring and
    issue lookup remain application/PostGIS operations supplied by the API.
    """
    try:
        llm = chat_model or _model()
        intent_llm = llm.with_structured_output(ChatIntent)
        email_llm = llm.with_structured_output(ComplaintDraft)
    except Exception as exc:
        # Client construction/structured-output setup must not disable the
        # deterministic route and issue tools.
        logger.warning("Chat model setup failed; using deterministic fallback (%s)", type(exc).__name__)
        intent_llm = None
        email_llm = None
    try:
        model_timeout = max(0.1, float(os.getenv("CHAT_LLM_TIMEOUT_SECONDS", "4")))
    except ValueError:
        model_timeout = 4.0

    async def interpret_message(state: ChatState) -> dict[str, Any]:
        if intent_llm is not None:
            try:
                intent = await asyncio.wait_for(
                    intent_llm.ainvoke(
                        [
                            (
                                "system",
                                "Classify the user's Hyderabad road-monitoring request. Use action=route "
                                "when they ask to travel, navigate, compare a route, or go from one "
                                "place to another. Extract origin and destination as concise place names; "
                                "if they say 'here', 'from my location', or equivalent, set origin to "
                                "'current location'. Use action=issue when they ask about a reported road "
                                "issue or want an inspection/repair complaint; preserve any UUID and "
                                "extract a short category/locality search phrase. Otherwise use action=other. "
                                "Never invent a place name or issue ID. Set language to en, te, or hi.",
                            ),
                            (
                                "human",
                                json.dumps(
                                    {
                                        "message": state["message"],
                                        "user_location": {
                                            "latitude": state.get("user_lat"),
                                            "longitude": state.get("user_lon"),
                                        },
                                    },
                                    ensure_ascii=False,
                                ),
                            ),
                        ]
                    ),
                    timeout=model_timeout,
                )
                return {"intent": ChatIntent.model_validate(intent), "llm_fallback": False}
            except Exception as exc:
                logger.warning(
                    "Chat intent model unavailable; using deterministic extraction (%s)",
                    type(exc).__name__,
                )
        intent = deterministic_chat_intent(
            state["message"], state.get("user_lat"), state.get("user_lon")
        )
        return {"intent": intent, "llm_fallback": True}

    async def run_route_audit(state: ChatState) -> dict[str, Any]:
        intent = state["intent"]
        audit = await route_auditor(intent, state)
        return {"route_audit": audit}

    async def find_issue_and_draft_email(state: ChatState) -> dict[str, Any]:
        intent = state["intent"]
        issue = await issue_resolver(intent, state)
        if email_llm is not None and not state.get("llm_fallback", False):
            try:
                email = await asyncio.wait_for(
                    email_llm.ainvoke(
                        [
                            (
                                "system",
                                "Draft a polite, structured citizen-to-authority email using "
                                "only the supplied database issue record. Do not invent a date, street, "
                                "impact, repair history, or official finding. Narrate the recorded road "
                                "condition, exact coordinates, ward and zone, corporation, recorded commuter "
                                "impact, and status. Respectfully request a field inspection and, if appropriate, "
                                "follow-up action without demanding it. Write in the requested language (en=English, "
                                "te=Telugu, hi=Hindi). This is a draft only; do not claim it was sent.",
                            ),
                            (
                                "human",
                                json.dumps(
                                    {"language": intent.language, "issue": issue},
                                    ensure_ascii=False,
                                    default=str,
                                ),
                            ),
                        ]
                    ),
                    timeout=model_timeout,
                )
                draft = ComplaintDraft.model_validate(email)
                return {"issue": issue, "email_draft": draft}
            except Exception as exc:
                logger.warning(
                    "Chat email model unavailable; using deterministic draft (%s)",
                    type(exc).__name__,
                )
        return {
            "issue": issue,
            "email_draft": deterministic_issue_email(issue, intent.language),
            "llm_fallback": True,
        }

    def other_response(_state: ChatState) -> dict[str, str]:
        return {
            "answer": (
                "I can compare Hyderabad road routes or look up a reported issue. "
                "For a route, provide a start and destination; for an issue, include "
                "its ID or a category and locality."
            )
        }

    builder = StateGraph(ChatState)
    builder.add_node("interpret_message", interpret_message)
    builder.add_node("route_audit", run_route_audit)
    builder.add_node("issue_lookup_and_email", find_issue_and_draft_email)
    builder.add_node("other_response", other_response)
    builder.add_edge(START, "interpret_message")
    builder.add_conditional_edges(
        "interpret_message",
        lambda state: state["intent"].action,
        {
            "route": "route_audit",
            "issue": "issue_lookup_and_email",
            "other": "other_response",
        },
    )
    builder.add_edge("route_audit", END)
    builder.add_edge("issue_lookup_and_email", END)
    builder.add_edge("other_response", END)
    return builder.compile()


rcmc_app = build_issue_graph()
