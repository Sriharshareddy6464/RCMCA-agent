# RCMCA AGENT - Frontend Context

**Product:** Road Condition Monitoring & Compliance Agent  
**Temporary Brand:** RCMCA AGENT  
**Target:** Android (Flutter) + Web (React)  
**Web Deployment:** Vercel  
**Backend:** LangGraph + FastAPI + PostgreSQL/PostGIS  
**Region:** Hyderabad, India

---

## 1. Project Objective

Redesign the existing basic Flutter frontend and develop an independent React web frontend as a fallback.

Both applications must connect to the **same existing backend and API**.

The application is a citizen-focused civic technology platform for:

- Monitoring road conditions.
- Visualizing reported road hazards.
- Planning routes while considering road conditions.
- Collecting citizen feedback on existing issues.
- Reporting new road issues.
- Generating and forwarding complaint drafts.
- Interacting with an AI road-monitoring assistant.

**Important:** This is a frontend redesign and implementation project. Do not rebuild or unnecessarily modify the existing backend.

## 2. Existing Technology Stack

| Layer | Technology |
|---|---|
| AI Agent | LangGraph |
| Backend API | FastAPI |
| Database | PostgreSQL |
| Geospatial Processing | PostGIS |
| Android Frontend | Flutter |
| Web Frontend | React |
| Web Hosting | Vercel |

Both frontends must use identical API contracts, data structures and backend functionality.

Inspect existing API endpoints and schemas before implementing integrations. Never invent endpoint names or response structures.

---

## 3. Brand Identity & Design System

### Design Direction

Create a modern, youthful, professional civic-tech SaaS application.

Design inspiration:
- Uber: navigation and location interactions.
- Rapido: mobility-focused simplicity.
- Swiggy/Zomato: accessible cards and intuitive navigation.
- Google Maps: geographical visualization and route interactions.

Use these as usability references, not templates to copy.

### Design Principles

- Map-centric interface.
- Minimal and clean layouts.
- Generous whitespace.
- Rounded cards and controls.
- Subtle shadows and elevation.
- Clear typography hierarchy.
- Consistent spacing.
- Smooth micro-interactions.
- High readability and accessibility.
- Responsive layouts.

Avoid excessive floating cards, cluttered interfaces, oversized text, heavy gradients and outdated government-portal aesthetics.

### Colour Palette

| Purpose | Colour | Hex |
|---|---|---|
| Primary | Deep Teal | `#087E83` |
| Primary Dark | Dark Teal | `#075B60` |
| Primary Light | Pale Aqua | `#DDF3F1` |
| Background | Cool Off-white | `#F5F8F9` |
| Surface | White | `#FFFFFF` |
| Primary Text | Charcoal Navy | `#172B36` |
| Secondary Text | Slate Grey | `#71818A` |
| Borders | Soft Grey | `#E2E9EC` |
| Success | Green | `#20B875` |
| Resolved | Blue | `#3985E8` |
| Active | Amber | `#E8AD24` |
| Impacting Others | Orange | `#F07832` |
| Environment | Red | `#DC525C` |
| Error | Muted Red | `#D95B5B` |

### Typography

**Preferred font:** Inter

| Element | Size |
|---|---:|
| Main content | 22–24 px |
| Section headings | 17–19 px |
| Card headings | 15–16 px |
| Body text | 14–15 px |
| Supporting text | 12–13 px |
| Navigation labels | 11–12 px |
| Coordinates | 11–12 px |

Use Bold, SemiBold, Medium and Regular weights appropriately.

### Component Styling

- Cards: 16–20 px radius.
- Buttons: 14–18 px radius.
- Input fields: 12–14 px radius.
- Minimum touch target: approximately 48 × 48 dp.
- Use subtle shadows.
- Maintain consistent spacing using an 8-point system.

---

## 4. Application Launch

Implement two launch stages.

### Stage 1: Splash Screen
- Duration: 0.8 seconds.
- Full-screen off-white background.
- Centered RCMCA logo.
- Product name.
- Tagline: "Better Roads. Safer Journeys."
- Subtle logo fade/scale animation.

### Stage 2: Loading Screen
- Duration: 0.2 seconds.
- Consistent brand background.
- Small animated teal loading indicator.
- Transition into Home.

**Total nominal duration: 1 second.**

Do not block the application if API, location or other initialization takes longer. Handle actual loading states independently.

---

## 5. Global Navigation

Implement five primary navigation destinations:

1. Home
2. Maps
3. Chatbot
4. Complaints
5. Profile

### Bottom Navigation

- Five equally distributed items.
- Icon above label.
- Active item highlighted using pale aqua.
- Active icon in deep teal.
- Inactive icons in slate grey.
- Smooth active-state transition.
- Persistent navigation across all five screens.
- Preserve screen state when switching tabs where practical.

Suggested icons:

| Screen | Icon |
|---|---|
| Home | House |
| Maps | Map |
| Chatbot | Robot / AI Assistant |
| Complaints | Clipboard / Document |
| Profile | User Circle |

### Common Header

Reserve consistent header space across all five screens.

- No heading.
- No title.
- No subtitle.
- No unnecessary text.
- Maintain safe-area alignment.
- Start screen content below the reserved header.

---

## 6. Screen Requirements

### 6.1 Home

Purpose: Personal road intelligence dashboard.

#### A. Time and Location

Display:

- Current time.
- Current date.
- Day of the week.
- Live user location.

Example:

`03:08 PM`

`Thursday, 19 November 2026`

`Gachibowli, Hyderabad`

Requirements:
- Device-based time and date.
- Android location permissions.
- Reverse geocoding where supported.
- Location refresh.
- Permission-denied and location-loading states.

#### B. Road Condition Notifications

Display newly registered road issues and updates submitted by other users.

Each notification card should contain:

- Issue category.
- Locality/road name.
- Issue status.
- Reported date and time.
- Reporter/source information, if available.
- Status-coloured indicator.
- Action to open the issue on Maps.

Example:

**New Pothole Reported**

Kukatpally, Hyderabad  
Registered · 5 minutes ago

**Waterlogging Reported**

Madhapur, Hyderabad  
Still Active · 18 minutes ago

Requirements:
- Fetch actual reports from the backend.
- Refresh automatically using polling or real-time subscriptions if supported.
- Highlight new reports.
- Provide empty, loading and error states.
- Never generate fake production notifications.

#### C. Additional Dashboard Cards

Include:
- Nearby active hazards.
- Recently resolved issues.
- Total reported issues.
- Latest road condition updates.

Keep the dashboard compact and informative.

---

### 6.2 Maps

**Highest visual priority.**

Replace the existing yellow-background map interface with a proper interactive geographic map.

#### A. Map Canvas

- Full available screen space.
- Light map theme.
- Visible roads, intersections and locality labels.
- Live user location.
- Direction indicator when available.
- Zoom, pan and rotate.
- Recenter-location button.
- No unnecessary floating cards.

#### B. Remove Existing UI

Completely remove:

- "97 hazards in view" card.
- Large Registered/Resolved/Active legend.
- Existing floating information panels.
- Bottom-positioned From/To panel.
- "Plan safer route" button.
- Camera/report button within the map screen.

#### C. Road Issue Markers

Every issue must have a geographical marker based on actual backend latitude and longitude.

Marker requirements:

- Status-specific colour.
- Issue-specific icon where appropriate.
- Clear pin shape.
- White/light inner icon.
- Subtle shadow.
- Tap interaction.
- Selected marker highlighting.

Status colours:

| Status | Colour |
|---|---|
| Registered | Green |
| Resolved | Blue |
| Still Active | Amber |
| Impacting Others | Orange |
| Ecosystem/Environment | Red |

**Important:** Keep issue category and issue status as separate attributes. Pin colour represents status, not issue category.

On marker selection, display:

- Issue category.
- Locality.
- Status.
- Latitude.
- Longitude.
- Reported date/time.

Use actual backend values.

#### D. Marker Clustering

- Cluster nearby markers.
- Expand clusters when zooming in.
- Prevent overlapping labels.
- Maintain map readability.

#### E. Compact Legend

Provide an optional small, unobtrusive legend identifying the five status colours.

Do not restore the original large floating legend card.

#### F. Origin and Destination Search

Move the complete From/To panel to the top of the map.

Design inspiration: Google Maps, Uber, Rapido and Ola.

Requirements:
- White rounded container.
- Compact vertical origin/destination fields.
- Green origin indicator.
- Red destination indicator.
- Swap-location control.
- Search/autocomplete.
- Current location as default origin.
- Manual location entry.
- Display readable locality names.

#### G. Route Confirmation

Display a right-facing arrow button when both fields contain valid locations.

Workflow:

1. Enter origin.
2. Enter destination.
3. Enable confirmation arrow.
4. Submit route request.
5. Show loading state.
6. Render returned route.

Do not use the previous "Plan safer route" button.

#### H. Safer Route Planning

Use the existing backend route-planning functionality.

Expected logic:

1. Discover candidate routes between origin and destination.
2. Use the existing K-nearest-neighbour-based approach where implemented.
3. Evaluate road connectivity and available road conditions.
4. Apply supported route constraints.
5. Identify major hazards along candidate routes.
6. Select the best eligible route.
7. Find an alternative if the selected route contains major hazards and a feasible alternative exists.

Consider supported restrictions such as:

- Narrow streets.
- Congested roads.
- Heavy traffic.
- Poor road conditions.
- Major active potholes.
- Waterlogging.
- Road blockages.
- Construction zones.

Do not assume all restrictions are implemented by the backend.

#### I. Route Visualization

Display:

- Recommended route.
- Alternative route, when available.
- Distance.
- Estimated travel time.
- Detected hazards.
- Relevant route warnings.

Use visually distinct route lines.

When no eligible alternative exists, explain this clearly.

Never claim a route is completely safe based only on available hazard data.

#### J. Hazard Highlighting Along Routes

When a selected route passes through a reported issue:

- Highlight the corresponding marker.
- Preserve its original status colour.
- Increase marker size.
- Add a subtle pulsing ring.
- Show issue category.
- Display distance from user or route when available.

Example:

**Pothole Detected Ahead**

Still Active  
250 metres ahead.

Use actual calculated distances, not illustrative values.

#### K. Live Location and Proximity Survey

The user's live location must remain visible.

Workflow:

1. Receive user location updates.
2. Compare location against existing issue coordinates.
3. Detect proximity to a previously reported issue.
4. Trigger a quick survey within the configured proximity threshold.
5. Display the existing application survey.
6. Submit the response to the backend.
7. Update issue information only according to the backend response.

Requirements:
- Reuse existing survey definitions.
- Avoid repeatedly prompting for the same issue.
- Provide dismiss functionality.
- Avoid distracting prompts while the user is moving.
- Respect location permissions and Android background-location restrictions.
- Do not treat an unverified response as a confirmed physical inspection.

---

### 6.3 Chatbot

Preserve the existing chatbot layout and functionality.

Only improve visual consistency and error handling.

#### UI Requirements

- Existing conversation layout.
- User and assistant message bubbles.
- Bottom message input.
- Send button.
- Message scrolling.
- Typing indicator.
- Empty-chat state.
- Retry functionality.
- Common header spacing.
- Global theme and typography.

#### Supported Capabilities

1. Check road conditions.
2. Find nearby road hazards.
3. Search by locality.
4. Plan safer routes.
5. Draft complaint emails.
6. Answer questions about registered issues.

#### Error Handling

Never expose raw backend exceptions.

Instead display:

**Couldn't process your message.**

Something went wrong while connecting to the assistant.

[Try Again]

Log actual technical errors for debugging.

Do not generate fake responses when the API is unavailable.

---

### 6.4 Complaints

Divide the screen into three visually distinct, approximately equal sections.

On mobile, stack the sections vertically within the available content area.

#### Section 1: Raise a New Issue

Only two primary input fields.

**Field 1: Issue Name**
- Text input.
- Placeholder: Describe the road issue.
- Example: Large pothole near Kukatpally junction.

**Field 2: Location**
- Select using a map pin.
- Alternatively paste latitude and longitude.
- Example: `17.xxxxxx, 78.xxxxxx`.
- Provide a map-selection icon.

Include a Submit/Raise Issue button.

Requirements:
- Validate both fields.
- Confirm selected location.
- Prevent duplicate submissions where possible.
- Connect to the existing report API.
- Display success/error feedback.
- Do not introduce additional mandatory fields.

#### Section 2: Drafted Complaints

Scrollable section.

Display AI-generated complaint drafts.

Each card contains:
- Complaint subject.
- Short text preview.
- Associated issue.
- Location.
- Draft creation date.
- Draft status.

Provide a right-facing arrow.

On selection:
1. Open complaint preview.
2. Allow review of complete text.
3. Allow editing/regeneration if supported.
4. Open the default device email application.
5. Populate email subject and body.
6. Allow manual review and sending.

Opening the email application does not mean the complaint has been sent.

#### Section 3: Confirmed Complaints

Scrollable section.

Each card contains:
- Complaint reference ID.
- Complaint title.
- Location.
- Submission date.
- Current status.
- Last update.

Possible statuses, only where supported:

- Submitted.
- Under Review.
- Assigned.
- In Progress.
- Resolved.
- Rejected.

#### Scrolling Requirements

- Three visually distinct sections.
- Section 2 has independent inner scrolling.
- Section 3 has independent inner scrolling.
- Section 1 remains compact.
- Long lists must not push the reporting form off-screen.
- Use equal-height section containers where practical.
- Prevent overflow on smaller Android screens.

---

### 6.5 Profile

Authentication does not currently exist in the backend.

Implement frontend-only placeholder screens.

#### Profile Landing

Display:
- Circular avatar placeholder.
- Generic profile illustration.
- Name: Guest User.
- Description: Your civic contribution starts here.
- Login button.
- Sign Up button.
- About RCMCA.
- Privacy Policy placeholder.
- Terms and Conditions placeholder.
- App version.

#### Login Screen

Fields:
- Email.
- Password.

Actions:
- Login.
- Forgot password placeholder.
- Navigate to Sign Up.

#### Registration Screen

Fields:
- Full name.
- Email.
- Mobile number.
- Password.
- Confirm password.

Actions:
- Register.
- Navigate to Login.

#### Restrictions

- Clearly identify authentication as unavailable.
- Do not pretend login or registration works.
- Do not store real passwords locally.
- Do not send credentials to unrelated endpoints.
- Keep screens ready for future authentication integration.

---

## 7. Shared Backend Integration

Both frontends must communicate with the existing FastAPI backend.

### Logical API Mapping

| Feature | Backend Operation |
|---|---|
| Home | Fetch latest road reports |
| Maps | Fetch road issues and coordinates |
| Route Planning | Submit origin, destination and constraints |
| Alternative Route | Request alternative route |
| Proximity Survey | Fetch survey and submit responses |
| Chatbot | Send messages to LangGraph |
| Raise Issue | Submit road issue |
| Draft Complaints | Retrieve/generate drafts |
| Complaint History | Retrieve previous complaints |
| Profile | Frontend-only placeholder |

These represent logical operations, not assumed endpoint names.

Inspect existing FastAPI routes and reuse their actual methods, paths, request schemas and response structures.

Document missing API functionality instead of fabricating responses.

### API Integration Rules

- Centralize API configuration.
- Use environment-specific base URLs.
- Maintain identical request/response contracts.
- Separate API logic from UI.
- Implement reusable services.
- Handle loading, empty and error states.
- Avoid hardcoded production data.
- Do not duplicate backend business logic.
- Do not rewrite LangGraph, FastAPI or PostGIS.

Use the FastAPI-generated OpenAPI specification as the shared API contract wherever possible.

---

## 8. Flutter Android Requirements

Redesign the existing Flutter application.

### Requirements

- Preserve working functionality.
- Reuse existing API integrations.
- Implement reusable widgets.
- Centralize theme and colours.
- Implement five-screen navigation.
- Separate UI, services and data models.
- Handle Android location permissions.
- Handle camera permissions where required.
- Support different Android screen sizes.
- Optimize map rendering and scrolling.
- Implement consistent loading/error/empty states.
- Maintain stable application performance.

### Suggested Structure

```text
lib/
├── main.dart
├── app/
│   ├── app.dart
│   ├── navigation.dart
│   └── routes.dart
├── core/
│   ├── theme/
│   ├── constants/
│   ├── services/
│   │   ├── api_service.dart
│   │   ├── location_service.dart
│   │   └── permission_service.dart
│   └── widgets/
├── features/
│   ├── home/
│   ├── maps/
│   ├── chatbot/
│   ├── complaints/
│   └── profile/
└── shared/
    ├── models/
    └── widgets/
```

This is a suggested structure. Do not unnecessarily rebuild the existing codebase.

---

## 9. React Web Fallback

Create an independent React frontend using the same backend.

### Requirements

- Same five navigation destinations.
- Same brand identity and design system.
- Same API contracts.
- Same business functionality wherever browser capabilities permit.
- Responsive desktop, tablet and mobile layouts.
- Browser location permissions.
- Interactive map.
- Chatbot.
- Complaint reporting and history.
- Temporary profile screens.

### Desktop Layout

- Left sidebar navigation.
- Main content canvas.
- Large map area.
- Compact route search panel.
- Floating issue information panels where appropriate.
- Responsive complaint cards.

### Mobile Layout

- Five-item bottom navigation.
- Map-first interface.
- Vertically stacked content.
- Mobile-friendly controls.

### Suggested Structure

```text
src/
├── app/
│   ├── App.jsx
│   ├── routes.jsx
│   └── navigation.jsx
├── components/
│   ├── common/
│   ├── navigation/
│   ├── cards/
│   ├── forms/
│   └── map/
├── features/
│   ├── home/
│   ├── maps/
│   ├── chatbot/
│   ├── complaints/
│   └── profile/
├── services/
│   ├── api.js
│   ├── location.js
│   └── routeService.js
├── styles/
│   ├── theme.css
│   ├── variables.css
│   └── global.css
└── main.jsx
```

Deploy independently using Vercel.

---

## 10. Animations and Interactions

Use lightweight animations.

| Element | Behaviour |
|---|---|
| Splash | Logo fade and scale |
| Navigation | Active indicator transition |
| Cards | Subtle fade |
| Map pins | Scale on selection |
| Nearby hazards | Gentle pulse |
| Route planning | Loading indicator |
| API success | Success feedback |
| API failure | Clear error state |
| Buttons | Brief press feedback |
| Chatbot | Typing indicator |

Prioritize smooth performance over decorative animation.

---

## 11. Global Development Constraints

1. Existing backend is the source of truth.
2. Both frontends must use the same FastAPI backend.
3. Do not introduce mock data into production.
4. Do not rewrite working backend functionality.
5. Do not invent API endpoints.
6. Never expose raw technical exceptions in the UI.
7. Never fabricate coordinates, distances or route information.
8. Never claim a complaint was submitted if it failed.
9. Never claim an issue was resolved without backend confirmation.
10. Do not introduce unsupported authentication.
11. Maintain identical branding across platforms.
12. Preserve existing working features.
13. Handle permissions and API failures gracefully.
14. Keep the UI responsive across supported devices.

---

## 12. Development Sequence

Implement incrementally.

| Phase | Deliverable |
|---|---|
| 1 | Inspect existing Flutter codebase |
| 2 | Inspect FastAPI routes and schemas |
| 3 | Establish design system |
| 4 | Implement splash and navigation |
| 5 | Implement Home |
| 6 | Implement Maps and route interactions |
| 7 | Integrate Chatbot |
| 8 | Implement Complaints |
| 9 | Implement temporary Profile |
| 10 | Test Flutter Android build |
| 11 | Develop React frontend |
| 12 | Integrate shared backend |
| 13 | Test both frontends |
| 14 | Deploy React to Vercel |

Do not attempt to develop both frontends simultaneously before validating the design system and API integration.

---

## 13. Final Acceptance Checklist

### Global
- [ ] Splash screen and loading sequence.
- [ ] Five navigation destinations.
- [ ] Consistent header spacing.
- [ ] Shared design system.

### Home
- [ ] Live time, date and day.
- [ ] Live location.
- [ ] New road issue notifications.
- [ ] Nearby hazards and statistics.

### Maps
- [ ] Interactive map.
- [ ] Actual geographical issue pins.
- [ ] Correct status colours.
- [ ] Latitude and longitude.
- [ ] Marker clustering.
- [ ] Visible user location.
- [ ] Top-positioned From/To fields.
- [ ] Route confirmation arrow.
- [ ] Constraint-aware route planning.
- [ ] Alternative route handling.
- [ ] Hazard highlighting.
- [ ] Proximity-based surveys.

### Chatbot
- [ ] LangGraph integration.
- [ ] Conversation history during session.
- [ ] Loading and typing states.
- [ ] Retry and error handling.

### Complaints
- [ ] Two-field issue reporting form.
- [ ] Map-based location selection.
- [ ] Manual coordinate input.
- [ ] Drafted complaint cards.
- [ ] Email application forwarding.
- [ ] Confirmed complaint history.
- [ ] Independent scrolling for Sections 2 and 3.

### Profile
- [ ] Guest profile.
- [ ] Login placeholder.
- [ ] Registration placeholder.
- [ ] No fake authentication.

### Deployment
- [ ] Flutter Android build.
- [ ] React responsive web build.
- [ ] Both connected to the same backend.
- [ ] API integration tested.
- [ ] React deployable on Vercel.

---

## 14. Development Instruction

Act as a senior frontend architect and mobile UI/UX engineer.

Before modifying code:

1. Inspect the existing Flutter project.
2. Understand existing screen implementations.
3. Inspect FastAPI endpoints and schemas.
4. Identify working and broken integrations.
5. Map existing backend functionality to the new screens.
6. Establish the design system.

Then implement the application incrementally.

**Do not rebuild the backend. Do not fabricate functionality. Do not sacrifice working integrations for visual changes.**

The final deliverable must be two functional frontend applications sharing one backend:

- Flutter Android application.
- React web application deployable on Vercel.

### Product Experience Goals

Users should immediately understand three things:

1. See what's happening on their roads.
2. Find routes that account for known road hazards.
3. Report issues and contribute to improving city infrastructure.

**RCMCA AGENT: Better Roads. Safer Journeys.**
