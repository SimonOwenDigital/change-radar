// Change Radar: assessment main form (ADR 0010 decision 4).
// Override reason is required whenever an override impact is set. Enforced on the form only: the flows never write
// override fields, and the 'record assessment override' flow records who changed them and when.
// Wrapped so the whole script runs in strict mode (solution checker rule web-use-strict-mode); the form calls
// ChangeRadar.Assessment.onLoad, published on window below.
(function () {
    "use strict";
    var ChangeRadar = window.ChangeRadar || {};
    ChangeRadar.Assessment = {
        onLoad: function (executionContext) {
            var form = executionContext.getFormContext();
            var impact = form.getAttribute("crdr_overrideimpact");
            if (!impact) { return; }
            impact.addOnChange(function (ctx) { ChangeRadar.Assessment.syncReason(ctx.getFormContext()); });
            ChangeRadar.Assessment.syncReason(form);
        },
        syncReason: function (form) {
            var impact = form.getAttribute("crdr_overrideimpact");
            var reason = form.getAttribute("crdr_overridereason");
            if (!impact || !reason) { return; }
            reason.setRequiredLevel(impact.getValue() === null ? "none" : "required");
        }
    };
    window.ChangeRadar = ChangeRadar;
}());
