# Reusable Components for IDP and Financial Institutions Net Calculations

This project contains mainly 3 components that can be reused for 2 different scenarios:

**IDP**: Intelligent Document Processing. It assumes a previous endpoint where the file binary is sent and a JSON comes back as a response with the text recognized in that file (for instance, Mulesoft IDP or similar technology). It uses DOC_PREVIEWER and JSON_FORM. Details on each link.

**LQC**: Liquidity Calculator Component. Details below in the related link.

## Repository layout

The two scenarios are kept in separate package directories with no code in
common, so each can be deployed — and eventually packaged — on its own:

```
force-app/idp/main/      IDP: fileJsonReview, jsonForm, jsonFormDemo,
                         fileJsonReviewMappingDemo, the Idp* mapping engine
                         classes, the IDP_* custom metadata types and the
                         pdfjs static resource
force-app/idp/examples/  Runnable IDP demonstrations — one folder each, with
                         their own mapping sets, fields, data and documents
force-app/lqc/           LQC: liquidityCalculator, lqcGrid, lqcDatatable,
                         lqcReport, lqcBanner, lqcUtils, the Lqc* Apex classes
                         and Custom_Configuration__mdt
```

Deploy one side with `sf project deploy start --source-dir force-app/idp/main`
(or `force-app/lqc`). The package directory stops at `force-app/idp/main`, so
the examples are never deployed unless you name one explicitly — see the
[examples index](force-app/idp/examples/README.md). Documentation stays at the
repository root because the guides cross-reference each other.

## Index

- **[DOC_PREVIEWER.md](DOC_PREVIEWER.md)** — The `fileJsonReview` document previewer: a split-screen LWC that shows a Salesforce file (PDF/JPG/PNG/GIF) next to an OCR-extracted JSON rendered as an editable form, so users can curate the result and store it back on `Document__c`. Covers business context (MuleSoft OCR pipeline), all dependencies (`jsonForm` child LWC, `FilePreviewController` Apex, `pdfjs` static resource), the public API, hosting from Screen Flows / parent LWCs / OmniStudio, PDF-rendering internals, org-to-org deployment steps, PDF.js maintenance, and troubleshooting.

- **[JSON_FORM.md](JSON_FORM.md)** — The reusable `jsonForm` component that renders any JSON as a hierarchical form of label/value textboxes and returns the modified JSON. Covers its public API and editing behavior, use from a parent LWC / Screen Flow / Lightning page, the `jsonFormDemo` test host, and the project's local setup commands (npm, tests, deploy).

- **[IDP_MAPPING.md](IDP_MAPPING.md)** — The IDP mapping engine: an `IDP_Mapping_Set__mdt`-driven, bulk-first Apex engine that takes the JSON reviewed in `fileJsonReview` and maps it onto the records reachable from the document, in three modes: Extraction (write the values), Compliance (canonicalize both sides through value types and report Match/Near/Mismatch) and Preview (return the planned old → new changes without writing). Covers the seven custom metadata types, the value type system (money, dates, phones, value maps, regex, custom handlers — with parse grades and confidence gates), the metadata-driven locale reference data (dial codes, decimal separators and month names in ~90 countries and ~20 languages), the invocable action for Screen Flows, `IdpBatchProcessor` for stored-JSON reprocessing, findings reference, error handling and extension points.

- **[force-app/idp/examples/README.md](force-app/idp/examples/README.md)** — Four runnable IDP examples set in a generic bank, each in its own folder with its own mapping set, value types, custom fields, permission set, seed data, sample PDF and step-by-step `sf` commands: **Business Account Opening** (Extraction, fixed sections, value maps), **Consolidated Statement** (Extraction with a repeating detail band and the batch demo), **Loan Offer Compliance** (Compliance with a custom `IIdpFindingHandler`) and **Letters of Executorship** (a custom object reached by child hop). Start here to see the engine working before configuring your own mapping set.

- **[LIQUIDITY_CALCULATOR.md](LIQUIDITY_CALCULATOR.md)** — The Liquidity Calculator (LQC): a configuration-driven, multi-tab editable grid for Case pages. Covers the `Custom_Configuration__mdt` configuration reference, the `ILqcPrefill` contract, and org-to-org deployment steps.
