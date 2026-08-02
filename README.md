# Reusable Components for IDP and Financial Institutions Net Calculations

This project contains mainly 3 components that can be reused for 2 different scenarios:

**IDP**: Intelligent Document Processing. It assumes a previous endpoint where the file binary is sent and a JSON comes back as a response with the text recognized in that file (for instance, Mulesoft IDP or similar technology). It uses DOC_PREVIEWER and JSON_FORM. Details on each link.

**LQC**: Liquidity Calculator Component. Details below in the related link.

## Index

- **[DOC_PREVIEWER.md](DOC_PREVIEWER.md)** — The `fileJsonReview` document previewer: a split-screen LWC that shows a Salesforce file (PDF/JPG/PNG/GIF) next to an OCR-extracted JSON rendered as an editable form, so users can curate the result and store it back on `Document__c`. Covers business context (MuleSoft OCR pipeline), all dependencies (`jsonForm` child LWC, `FilePreviewController` Apex, `pdfjs` static resource), the public API, hosting from Screen Flows / parent LWCs / OmniStudio, PDF-rendering internals, org-to-org deployment steps, PDF.js maintenance, and troubleshooting.

- **[JSON_FORM.md](JSON_FORM.md)** — The reusable `jsonForm` component that renders any JSON as a hierarchical form of label/value textboxes and returns the modified JSON. Covers its public API and editing behavior, use from a parent LWC / Screen Flow / Lightning page, the `jsonFormDemo` test host, and the project's local setup commands (npm, tests, deploy).

- **[JSON_FIELD_MAPPING.md](JSON_FIELD_MAPPING.md)** — The JSON field mapping engine: a `JSON_Field_Mapping__mdt`-driven Apex service that takes the JSON reviewed in `fileJsonReview` and maps it onto the records reachable from the file (`Document__c` → `Case` → `Account` / `Estate_Case__c`) in two modes: Data Extraction (write the values) or Compliance Check (compare with the stored values and report mismatches, optionally firing a custom `IComplianceMismatchHandler` action). Covers the mapping rule reference, the invocable action for Screen Flows, the `fileJsonReviewMappingDemo` example LWC, error handling and extension points.

- **[LIQUIDITY_CALCULATOR.md](LIQUIDITY_CALCULATOR.md)** — The Liquidity Calculator (LQC): a configuration-driven, multi-tab editable grid for Case pages. Covers the `Custom_Configuration__mdt` configuration reference, the `ILqcPrefill` contract, and org-to-org deployment steps.
