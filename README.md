# JsonLwc

Salesforce DX project. The documentation is split by feature:

## Index

- **[DOC_PREVIEWER.md](DOC_PREVIEWER.md)** — The `fileJsonReview` document previewer: a split-screen LWC that shows a Salesforce file (PDF/JPG/PNG/GIF) next to an OCR-extracted JSON rendered as an editable form, so users can curate the result and store it back on `Document__c`. Covers business context (MuleSoft OCR pipeline), all dependencies (`jsonForm` child LWC, `FilePreviewController` Apex, `pdfjs` static resource), the public API, hosting from Screen Flows / parent LWCs / OmniStudio, PDF-rendering internals, org-to-org deployment steps, PDF.js maintenance, and troubleshooting.

- **[LIQUIDITY_CALCULATOR.md](LIQUIDITY_CALCULATOR.md)** — The Liquidity Calculator (LQC): a configuration-driven, multi-tab editable grid for Case pages. Covers the `Custom_Configuration__mdt` configuration reference, the `ILqcPrefill` contract, and org-to-org deployment steps.
