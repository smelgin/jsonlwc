# Reusable Components for IDP

**IDP**: Intelligent Document Processing. It assumes a previous endpoint where the file binary is sent and a JSON comes back as a response with the text recognized in that file (for instance, Mulesoft IDP or similar technology). It uses `fileJsonReview` (the document previewer) and `jsonForm`.

> **LQC** (Liquidity Calculator) used to live here under `force-app/lqc`. It now has its own
> repository: **[smelgin/lqc](https://github.com/smelgin/lqc)**. The two never shared code.

## Documentation

All documentation — component references, the IDP mapping engine, configuration guide, backlog and worked examples — lives in the **[project wiki](https://github.com/smelgin/jsonlwc/wiki)**.

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
name one explicitly — see the [examples index](https://github.com/smelgin/jsonlwc/wiki/Examples) in the wiki.
