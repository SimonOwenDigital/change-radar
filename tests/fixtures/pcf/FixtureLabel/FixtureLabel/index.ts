// FIXTURE: Change Radar test asset (not real). A minimal code component used to test pcf_control detection.
import { IInputs, IOutputs } from "./generated/ManifestTypes";

export class FixtureLabel implements ComponentFramework.StandardControl<IInputs, IOutputs> {
    private label!: HTMLSpanElement;

    public init(context: ComponentFramework.Context<IInputs>, notifyOutputChanged: () => void, state: ComponentFramework.Dictionary, container: HTMLDivElement): void {
        this.label = document.createElement("span");
        container.appendChild(this.label);
    }

    public updateView(context: ComponentFramework.Context<IInputs>): void {
        this.label.textContent = `[fixture] ${context.parameters.value.raw ?? ""}`;
    }

    public getOutputs(): IOutputs {
        return {};
    }

    public destroy(): void {
        // Nothing to clean up.
    }
}
