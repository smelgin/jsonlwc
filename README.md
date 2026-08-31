# Reusable Components for IDP

**IDP**: Intelligent Document Processing. It assumes a previous endpoint where the file binary is sent and a JSON comes back as a response with the text recognized in that file (for instance, Mulesoft IDP or similar technology). It uses DOC_PREVIEWER and JSON_FORM. Details on each link.

> **LQC** (Liquidity Calculator) used to live here under `force-app/lqc`. It now has its own
> repository: **[smelgin/lqc](https://github.com/smelgin/lqc)**. The two never shared code.

## Repository layout

```
force-app/idp/main/      IDP: fileJsonReview, jsonForm, jsonFormDemo,
                         fileJsonReviewMappingDemo, the Idp* mapping engine
                         classes, the IDP_* custom metadata types and the
                         pdfjs static resource
force-app/idp/examples/  Runnable IDP demonstrations — one folder each, with
                         their own mapping sets, fields, data and documents
```

Deploy with `sf project deploy start --source-dir force-app/idp/main`. The package
directory stops at `force-app/idp/main`, so the examples are never deployed unless you
name one explicitly — see the [examples index](force-app/idp/examples/README.md).
Documentation stays at the repository root because the guides cross-reference each other.

## Index

- **[DOC_PREVIEWER.md](DOC_PREVIEWER.md)** — The `fileJsonReview` document previewer: a split-screen LWC that shows a Salesforce file (PDF/JPG/PNG/GIF) next to an OCR-extracted JSON rendered as an editable form, so users can curate the result and store it back on `Document__c`. Covers business context (MuleSoft OCR pipeline), all dependencies (`jsonForm` child LWC, `FilePreviewController` Apex, `pdfjs` static resource, and `IdpMappingController` for the Preview button), the public API including the forwarded form capabilities and previewing a save before making it, hosting from Screen Flows / parent LWCs / OmniStudio, PDF-rendering internals, org-to-org deployment steps, PDF.js maintenance, and troubleshooting.

- **[JSON_FORM.md](JSON_FORM.md)** — The reusable `jsonForm` component that renders any JSON as a hierarchical form of label/value textboxes and returns the modified JSON. Covers its public API and editing behavior, use from a parent LWC / Screen Flow / Lightning page, the `jsonFormDemo` test host, and the project's local setup commands (npm, tests, deploy).

- **[IDP_MAPPING.md](IDP_MAPPING.md)** — The IDP mapping engine: an `IDP_Mapping_Set__mdt`-driven, bulk-first Apex engine that takes the JSON reviewed in `fileJsonReview` and maps it onto the records reachable from the document, in three modes: Extraction (write the values), Compliance (canonicalize both sides through value types and report Match/Near/Mismatch) and Preview (return the planned old → new changes without writing). Covers the four custom metadata types, the value type system (money, dates, phones, value maps, regex, custom handlers — with parse grades and confidence gates), the metadata-driven locale reference data (dial codes, decimal separators and month names, seeded for the Southern and East African markets), the invocable action for Screen Flows, `IdpBatchProcessor` for stored-JSON reprocessing, findings reference, error handling and extension points.

- **[IDP_CONFIGURATION.md](IDP_CONFIGURATION.md)** — The admin manual for configuring a document type: the JSON that lives in a mapping set's `Definition__c`, every section and rule key and what it means, value map dictionaries, worked examples for the jobs that come up most (add a field, retire a rule, protect hand-typed values, verify instead of write), and exactly what the engine does with each kind of mistake. Written for the person editing the rules, not the person who wrote the engine.

- **[BACKLOG.md](BACKLOG.md)** — Candidate enhancements for the three deliverables in `force-app/idp/main`, split into `jsonForm`, `fileJsonReview` and the IDP mapping engine (Engine/Apex, Value Types, Config authoring and admin), with what is already done marked as such and a design note for Hybrid mode.

- **[force-app/idp/examples/README.md](force-app/idp/examples/README.md)** — Four runnable IDP examples set in a generic bank, each in its own folder with its own mapping set, value types, custom fields, permission set, seed data, sample PDF and step-by-step `sf` commands: **Business Account Opening** (Extraction, fixed sections, value maps), **Consolidated Statement** (Extraction with a repeating detail band and the batch demo), **Loan Offer Compliance** (Compliance with a custom `IIdpFindingHandler`) and **Letters of Executorship** (a custom object reached by child hop). Start here to see the engine working before configuring your own mapping set.
