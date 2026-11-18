# Simple and Advanced

The main queue and Preferences use more readable status and explanation text, and Preferences adapts to available space. See the [native readability and disclosure audit](native-ux-audit.md) for the design background.

Chunky starts in Simple mode on both new and existing installations. The switch is at the top of Preferences and the main sidebar. It changes presentation only: saved models, dimensions, worker profiles, credentials, collection names and processing options remain active.

Simple Preferences starts with an output choice. **Save files** shows the file format and destination folder. **Add to a searchable library** shows the saved collection and embedding model, compatibility warnings, and service checks. Named buttons open the relevant Advanced page when a connection or model needs configuration. Switching back preserves the selected page and ongoing local database operations.

Advanced exposes all six Preferences pages and specialist navigation tools. If a specialist tool is already open when switching to Simple, its navigation item remains available until you leave it.

## Connections and errors

A status is the result of the last check, not a promise that a service is still reachable. Changing an endpoint or database route invalidates its result. Simple mode identifies worker-to-Cloud routing explicitly and does not display a local Qdrant check as Cloud validation. That route is verified by the worker during ingest/search; checks from this Mac are labeled accordingly. Qdrant checks use a separate temporary client and verify collection access, without disconnecting processing jobs or selecting another collection. Ollama checks list available models without changing the saved model or its dimensions. Model selection still probes dimensions for that selected model.

Endpoint, model, credential and dimension fields keep edits pending until **Apply**, **Save and test**, or Return. Invalid input leaves the previous saved value intact and explains how to correct it. Worker profile fields save together with **Save** or Return; **Use** also validates before applying the profile. Database credentials and endpoint changes are locked during document processing.

Connection errors are selectable and offer **Copy details**. Copies include the operation and redact known credentials, bearer tokens and URL credentials/query parameters. Configuration summaries in the sidebar use neutral icons: a configured address is not a successful health check.

Remote HTTP services use **Test connection** or **Check reachability**, because there is no persistent connection for the user to disconnect. Testing Qdrant similarly does not control the app's automatically managed gRPC connection. Dedicated local Colima/Qdrant processes have genuine Start and Stop controls in Advanced → Qdrant; see [local Qdrant](local-qdrant.md).

## Design references

[VLC Preferences](https://docs.videolan.me/vlc-user/desktop/3.0/en/basic/settings/preferences.html) separates common controls from detailed configuration. [OBS's overview](https://obsproject.com/kb/obs-studio-overview) similarly starts with Simple output settings and directs users to Advanced for detailed control. Chunky follows that progressive disclosure pattern while retaining one saved configuration across both modes.

The owner waived additional screenshots for this iteration. Behavioral tests, the native macOS build, independent review and CI remain required; no screenshot result is claimed.

## Appearance and finding settings

The Appearance selector at the top of Preferences offers System, Light and Dark in both modes. System is the default and follows macOS. The choice is saved and applies immediately across Chunky windows and sheets; it does not alter macOS appearance for other apps.

Use **Find a setting…** to search setting categories by terms such as OCR, model, timeout, folder or dark. Choose a result to open its Advanced pane and expand tuning sections. Dataset download results open the Datasets window, where its folder is configured. Clear search to return to the current presentation. Searching keeps the existing Advanced tabs mounted, preserving endpoint drafts and ongoing local database work. Results navigate to a pane rather than filtering or recreating its controls.

Advanced embedding tuning, metadata fields and database tuning use disclosure groups with summaries of current values. Provider/model/dimensions, connection errors and service controls stay visible. Collapsing these groups changes presentation only; it does not reset their saved values. Simple mode keeps its short setup links visible.
