// Purpose: Lightning Web Component controller for the Deep Clone Account quick action.
// Author: Saransh
import { LightningElement, api, wire } from "lwc";
import { CloseActionScreenEvent } from "lightning/actions";
import { CurrentPageReference, NavigationMixin } from "lightning/navigation";
import { RefreshEvent } from "lightning/refresh";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import getContext from "@salesforce/apex/DeepCloneController.getContext";
import cloneFacility from "@salesforce/apex/DeepCloneController.cloneFacility";
import closeFacility from "@salesforce/apex/DeepCloneController.closeFacility";

const ACTION_CLOSE = "closeFacility";
const ACTION_DEEP_CLONE = "deepClone";
const SCREEN_ACTION = "action";
const SCREEN_CLOSE = "close";
const SCREEN_DEEP_CLONE = "deepClone";

const ACTION_OPTIONS = [
  {
    value: ACTION_CLOSE,
    label: "Close Facility",
    description: "Close this Facility and end its related records."
  },
  {
    value: ACTION_DEEP_CLONE,
    label: "Deep Clone",
    description: "Create a replacement Facility with carried-forward records."
  }
];

const CLONE_STEP_LABELS = [
  "Facility",
  "Care Program Team Members",
  "Healthcare Practitioner Facilities",
  "Business Licenses",
  "Assets"
];

const CLOSE_STEP_LABELS = [
  "Facility",
  "Identifiers",
  "Care Program Team Members",
  "Healthcare Practitioner Facilities",
  "Assets"
];

const SUMMARY_FIELDS = [
  { label: "Facility Name", field: "facilityName" },
  { label: "Address", field: "address", kind: "address" },
  { label: "Start Date", field: "startDate" },
  { label: "End Date", field: "endDate" },
  { label: "WDFA", field: "wdfa" },
  { label: "Facility ID", field: "facilityId" },
  { label: "ACP Number", field: "acpNumber" },
  { label: "DSR ID", field: "dsrId" }
];

const QUESTION_FIELDS = [
  {
    toggleLabel: "Facility Name changing?",
    inputLabel: "New Facility Name",
    toggleField: "facilityNameChanging",
    valueField: "newFacilityName",
    contextField: "facilityName",
    kind: "text"
  },
  {
    toggleLabel: "Address changing?",
    inputLabel: "New Facility Address",
    toggleField: "addressChanging",
    contextField: "address",
    kind: "address"
  },
  {
    toggleLabel: "Start Date changing?",
    inputLabel: "New Start Date",
    toggleField: "startDateChanging",
    valueField: "newStartDate",
    contextField: "startDate",
    kind: "date"
  },
  {
    toggleLabel: "End Date changing?",
    inputLabel: "Old Facility End Date",
    toggleField: "endDateChanging",
    valueField: "newEndDate",
    contextField: "endDate",
    kind: "date"
  },
  {
    toggleLabel: "WDFA changing?",
    inputLabel: "New WDFA",
    toggleField: "wdfaChanging",
    valueField: "newWdfa",
    contextField: "wdfa",
    kind: "text"
  },
  {
    toggleLabel: "Facility ID changing?",
    inputLabel: "New Facility ID",
    toggleField: "facilityIdChanging",
    valueField: "newFacilityId",
    contextField: "facilityId",
    kind: "text"
  },
  {
    toggleLabel: "ACP Number changing?",
    inputLabel: "New ACP Number",
    toggleField: "acpNumberChanging",
    valueField: "newAcpNumber",
    contextField: "acpNumber",
    kind: "text"
  },
  {
    toggleLabel: "DSR ID changing?",
    inputLabel: "New DSR ID",
    toggleField: "dsrIdChanging",
    valueField: "newDsrId",
    contextField: "dsrId",
    kind: "text"
  }
];

const ADDRESS_FORM_FIELDS = [
  "newStreet",
  "newCity",
  "newState",
  "newPostalCode",
  "newCountry"
];
const ADDRESS_VALIDITY_FIELDS = [
  "street",
  "city",
  "province",
  "postalCode",
  "country"
];
const DATE_REQUEST_FIELDS = [
  ["newStartDate", "startDateChanging"],
  ["newEndDate", "endDateChanging"]
];

export default class DeepClone extends NavigationMixin(LightningElement) {
  _recordId;

  form = {
    facilityNameChanging: false,
    newFacilityName: "",
    addressChanging: false,
    newStreet: "",
    newCity: "",
    newState: "",
    newPostalCode: "",
    newCountry: "",
    startDateChanging: false,
    newStartDate: "",
    endDateChanging: false,
    newEndDate: "",
    wdfaChanging: false,
    newWdfa: "",
    facilityIdChanging: false,
    newFacilityId: "",
    acpNumberChanging: false,
    newAcpNumber: "",
    dsrIdChanging: false,
    newDsrId: ""
  };

  context;
  selectedAction = "";
  screen = SCREEN_ACTION;
  closeForm = {
    endDate: ""
  };
  isLoading = true;
  isCloning = false;
  isClosing = false;
  loadError;
  cloneError;
  activeStepIndex = 0;
  completedStepIndex = -1;
  resultStepCounts = {};
  progressTimer;
  missingRecordIdValidationKey = 0;
  contextLoadStarted = false;

  /**
   * Purpose: Receives the Account Id from the quick action host so Apex knows which Facility to clone.
   */
  @api
  get recordId() {
    return this._recordId;
  }

  /**
   * Purpose: Stores the Account Id and starts context loading once the component is ready.
   */
  set recordId(value) {
    this._recordId = value;
    this.loadContextWhenReady();
  }

  /**
   * Purpose: Reads the Account Id from the page reference as a backup when the quick action has not assigned recordId yet.
   */
  @wire(CurrentPageReference)
  setCurrentPageReference(pageReference) {
    const pageRecordId =
      pageReference?.state?.recordId || pageReference?.attributes?.recordId;
    if (!this._recordId && pageRecordId) {
      this._recordId = pageRecordId;
      this.loadContextWhenReady();
    }
  }

  /**
   * Purpose: Starts the initial record-id validation and loads Account context when the modal opens.
   */
  connectedCallback() {
    this.queueMissingRecordIdValidation();
    this.loadContextWhenReady();
  }

  /**
   * Purpose: Cleans up timers and pending validation when the modal closes.
   */
  disconnectedCallback() {
    this.stopProgress();
    this.clearMissingRecordIdValidation();
  }

  /**
   * Purpose: Shows the Account name in the modal header, defaulting to Account if Apex has not returned a name.
   */
  get accountName() {
    return this.context?.accountName || "Account";
  }

  get panelHeader() {
    if (this.showDeepCloneForm) {
      return "Deep Clone";
    }
    if (this.showCloseFacilityForm) {
      return "Close Facility";
    }
    return "Facility Action";
  }

  get isBusy() {
    return this.isCloning || this.isClosing;
  }

  get actionOptions() {
    return ACTION_OPTIONS.map((option) => ({
      ...option,
      checked: this.selectedAction === option.value
    }));
  }

  /**
   * Purpose: Builds the current Facility values displayed at the top of the modal.
   */
  get summaryValues() {
    return SUMMARY_FIELDS.map(({ label, field, kind }) => ({
      label,
      value:
        kind === "address"
          ? this.displayAddress(this.context)
          : this.displayValue(this.context?.[field])
    }));
  }

  /**
   * Purpose: Builds the clone-time change question rows used by the template.
   */
  get questionRows() {
    return QUESTION_FIELDS.map((fieldConfig) => {
      const isAddress = fieldConfig.kind === "address";
      const isDate = fieldConfig.kind === "date";
      const isScalar = !isAddress;
      return {
        ...fieldConfig,
        checked: this.form[fieldConfig.toggleField],
        showInput: this.form[fieldConfig.toggleField],
        showCarryForward: !this.form[fieldConfig.toggleField],
        value: fieldConfig.valueField ? this.form[fieldConfig.valueField] : "",
        currentValue: isAddress
          ? this.displayAddress(this.context)
          : this.displayValue(this.context?.[fieldConfig.contextField]),
        isAddress,
        isScalar,
        inputType: isDate ? "date" : "text",
        requiredMessage: `${fieldConfig.inputLabel} is required.`,
        street: this.form.newStreet,
        city: this.form.newCity,
        province: this.form.newState,
        postalCode: this.form.newPostalCode,
        country: this.form.newCountry
      };
    });
  }

  /**
   * Purpose: Identifies when the current Account should be blocked because it is not a Facility.
   */
  get isBlocked() {
    return this.context && !this.context.isFacility;
  }

  /**
   * Purpose: Shows the load error section only after loading has finished and an error exists.
   */
  get showLoadError() {
    return !this.isLoading && !!this.loadError;
  }

  /**
   * Purpose: Shows the non-Facility message only when there is no load error and the Account is blocked.
   */
  get showBlocked() {
    return !this.isLoading && !this.loadError && this.isBlocked;
  }

  /**
   * Purpose: Shows the main form only when loading succeeded and the Account is a Facility.
   */
  get showForm() {
    return !this.isLoading && !this.loadError && !this.isBlocked;
  }

  get showActionChoice() {
    return this.showForm && this.screen === SCREEN_ACTION;
  }

  get showDeepCloneForm() {
    return this.showForm && this.screen === SCREEN_DEEP_CLONE;
  }

  get showCloseFacilityForm() {
    return this.showForm && this.screen === SCREEN_CLOSE;
  }

  get closeStartDate() {
    return this.context?.startDate || "";
  }

  /**
   * Purpose: Formats the record type message shown when a user opens Deep Clone on a non-Facility Account.
   */
  get recordTypeLabel() {
    if (!this.context) {
      return "";
    }
    return this.context.recordTypeName
      ? `Current record type: ${this.context.recordTypeName}`
      : "Current record type is not Facility.";
  }

  /**
   * Purpose: Checks whether the user selected at least one change before allowing Deep Clone to start.
   */
  get hasSelectedChange() {
    return QUESTION_FIELDS.some(({ toggleField }) => this.form[toggleField]);
  }

  get hasSelectedAction() {
    return !!this.selectedAction;
  }

  get isNextDisabled() {
    return this.isBusy || !this.hasSelectedAction;
  }

  get showBackButton() {
    return this.showDeepCloneForm || this.showCloseFacilityForm;
  }

  get showProgressModal() {
    return this.isCloning || this.isClosing;
  }

  get progressTitle() {
    return this.isClosing
      ? "Close Facility in progress"
      : "Deep Clone in progress";
  }

  get currentStepLabels() {
    return this.isClosing ? CLOSE_STEP_LABELS : CLONE_STEP_LABELS;
  }

  /**
   * Purpose: Disables the Start button while loading, cloning, blocked by record type, or no slider is selected.
   */
  get isStartDisabled() {
    return (
      this.isLoading ||
      this.isBusy ||
      this.isBlocked ||
      !this.hasSelectedChange
    );
  }

  /**
   * Purpose: Converts completed progress steps into a percentage for the circular progress ring.
   */
  get progressValue() {
    const stepCount = this.currentStepLabels.length;
    return Math.round(
      ((this.completedStepIndex + 1) / stepCount) * 100
    );
  }

  /**
   * Purpose: Shows the user which high-level action step is currently active.
   */
  get activeProgressLabel() {
    const label = this.currentStepLabels[this.activeStepIndex];
    return `${this.isClosing ? "Updating" : "Working on"} ${label}.`;
  }

  /**
   * Purpose: Builds the progress modal rows with active, done, and waiting state values for the template.
   */
  get progressSteps() {
    return this.currentStepLabels.map((label, index) => {
      const state =
        index <= this.completedStepIndex
          ? "done"
          : index === this.activeStepIndex
            ? "active"
            : "waiting";
      const count = this.resultStepCounts[label];
      return {
        key: label,
        label,
        countLabel: count === undefined ? "" : `${count} records`,
        className: `progress-step progress-step_${state}`,
        isActive: state === "active",
        isDone: state === "done"
      };
    });
  }

  /**
   * Purpose: Calls Apex to load Facility context and current values for the selected Account.
   */
  async loadContext() {
    this.isLoading = true;
    this.loadError = undefined;
    this.contextLoadStarted = true;

    try {
      this.context = await getContext({ recordId: this.recordId });
    } catch (error) {
      this.loadError = this.normalizeError(error);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * Purpose: Starts context loading only after the component has both a record Id and a connected DOM.
   */
  loadContextWhenReady() {
    if (!this.recordId || this.contextLoadStarted || !this.isConnected) {
      return;
    }
    this.clearMissingRecordIdValidation();
    this.loadContext();
  }

  /**
   * Purpose: Shows a clear UI error if Salesforce never provides the Account Id to the quick action.
   */
  queueMissingRecordIdValidation() {
    this.clearMissingRecordIdValidation();
    const validationKey = this.missingRecordIdValidationKey;
    Promise.resolve().then(() => {
      if (
        validationKey === this.missingRecordIdValidationKey &&
        !this.recordId &&
        !this.contextLoadStarted
      ) {
        this.isLoading = false;
        this.loadError =
          "Unable to determine the Account record for this Facility action. Launch it from an Account record page.";
      }
    });
  }

  /**
   * Purpose: Cancels any pending missing-record-id validation by advancing the validation key.
   */
  clearMissingRecordIdValidation() {
    this.missingRecordIdValidationKey += 1;
  }

  handleActionToggle(event) {
    this.selectedAction = event.target.checked ? event.target.dataset.action : "";
    this.cloneError = undefined;
  }

  handleNext() {
    if (!this.selectedAction) {
      return;
    }
    this.cloneError = undefined;
    this.screen =
      this.selectedAction === ACTION_CLOSE ? SCREEN_CLOSE : SCREEN_DEEP_CLONE;
  }

  handleBack() {
    this.cloneError = undefined;
    this.clearCustomValidity();
    this.screen = SCREEN_ACTION;
  }

  /**
   * Purpose: Updates the form when a user turns one of the yes/no change toggles on or off.
   */
  handleToggle(event) {
    const field = event.target.dataset.field;
    this.form = {
      ...this.form,
      [field]: event.target.checked
    };
  }

  /**
   * Purpose: Stores text and date replacement values entered by the user.
   */
  handleInput(event) {
    const field = event.target.dataset.field;
    this.form = {
      ...this.form,
      [field]: event.target.value
    };
    this.clearCustomValidity();
  }

  handleCloseInput(event) {
    this.closeForm = {
      ...this.closeForm,
      [event.target.dataset.field]: event.target.value
    };
    this.cloneError = undefined;
    this.validateCloseEndDate(true);
  }

  /**
   * Purpose: Stores the composite address parts entered through lightning-input-address.
   */
  handleAddressInput(event) {
    this.form = {
      ...this.form,
      newStreet: event.target.street || "",
      newCity: event.target.city || "",
      newState: event.target.province || "",
      newPostalCode: event.target.postalCode || "",
      newCountry: event.target.country || ""
    };
    this.clearCustomValidity();
  }

  /**
   * Purpose: Validates the form, starts progress feedback, calls Apex to clone the Facility, and opens the new Account.
   */
  async handleStart() {
    this.cloneError = undefined;
    if (!this.validate()) {
      return;
    }

    this.isCloning = true;
    this.activeStepIndex = 0;
    this.completedStepIndex = -1;
    this.resultStepCounts = {};
    this.startProgress();

    try {
      const result = await cloneFacility({
        recordId: this.recordId,
        request: this.buildCloneRequest()
      });
      this.applyResultSteps(result.steps || []);
      this.completedStepIndex = this.currentStepLabels.length - 1;
      this.stopProgress();
      this.showToast(
        "Deep Clone complete",
        "The new facility is opening now.",
        "success"
      );
      this.navigateToNewFacility(result.newAccountId);
      this.dispatchEvent(new CloseActionScreenEvent());
    } catch (error) {
      this.stopProgress();
      this.cloneError = this.normalizeError(error);
      this.showToast("Deep Clone failed", this.cloneError, "error");
    } finally {
      this.isCloning = false;
    }
  }

  async handleFinish() {
    this.cloneError = undefined;
    if (!this.validateClose()) {
      return;
    }

    this.isClosing = true;
    this.activeStepIndex = 0;
    this.completedStepIndex = -1;
    this.resultStepCounts = {};
    this.startProgress();

    try {
      const result = await closeFacility({
        recordId: this.recordId,
        request: this.buildCloseRequest()
      });
      this.applyResultSteps(result.steps || []);
      this.completedStepIndex = this.currentStepLabels.length - 1;
      this.stopProgress();
      await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
      this.dispatchEvent(new RefreshEvent());
      this.showToast(
        "Facility closed",
        result?.message || "The Facility has been closed.",
        "success"
      );
      this.dispatchEvent(new CloseActionScreenEvent());
    } catch (error) {
      this.stopProgress();
      this.cloneError = this.normalizeError(error);
      this.showToast("Close Facility failed", this.cloneError, "error");
    } finally {
      this.isClosing = false;
    }
  }

  /**
   * Purpose: Closes the quick action modal when the user cancels.
   */
  handleCancel() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  /**
   * Purpose: Builds an Apex-safe request, using null for blank date values so Aura can bind the Date fields.
   */
  buildCloneRequest() {
    const request = { ...this.form };
    DATE_REQUEST_FIELDS.forEach(([dateField, toggleField]) => {
      request[dateField] =
        request[toggleField] && request[dateField] ? request[dateField] : null;
    });
    return request;
  }

  buildCloseRequest() {
    return {
      endDate: this.closeForm.endDate || null
    };
  }

  /**
   * Purpose: Performs client-side checks so Apex is not called without an Account Id or required new values.
   */
  validate() {
    if (!this.recordId) {
      this.cloneError =
        "Account Id is required. Launch this action from an Account record page.";
      return false;
    }

    this.clearCustomValidity();
    let isValid = true;

    if (this.form.addressChanging && !this.hasAddressInput()) {
      this.setAddressValidity("Enter at least one new address value.");
      isValid = false;
    }

    return this.reportInputsValidity() && isValid;
  }

  validateClose() {
    if (!this.recordId) {
      this.cloneError =
        "Account Id is required. Launch this action from an Account record page.";
      return false;
    }

    this.clearCustomValidity();
    const hasValidEndDate = this.validateCloseEndDate(false);
    return this.reportInputsValidity() && hasValidEndDate;
  }

  validateCloseEndDate(report) {
    const input = this.closeEndDateInput;
    if (!input) {
      return true;
    }

    let message = "";
    if (this.closeForm.endDate) {
      if (!this.closeStartDate) {
        message = "Enter Start Date first on the Facility.";
      } else if (this.closeForm.endDate <= this.closeStartDate) {
        message = "End Date must be after Start Date.";
      }
    }

    input.setCustomValidity(message);
    if (report) {
      input.reportValidity();
    }
    return !message;
  }

  clearCustomValidity() {
    this.template
      .querySelectorAll("lightning-input")
      .forEach((input) => this.clearInputValidity(input));
    this.clearAddressValidity(this.addressInput);
  }

  clearInputValidity(input) {
    if (input?.setCustomValidity) {
      input.setCustomValidity("");
    }
  }

  clearAddressValidity(addressInput) {
    if (!addressInput?.setCustomValidityForField) {
      return;
    }
    ADDRESS_VALIDITY_FIELDS.forEach((field) =>
      addressInput.setCustomValidityForField("", field)
    );
  }

  setAddressValidity(message) {
    this.addressInput?.setCustomValidityForField?.(message, "street");
  }

  reportInputsValidity() {
    return [
      ...this.template.querySelectorAll(
        "lightning-input, lightning-input-address"
      )
    ]
      .reduce((isValid, input) => input.reportValidity() && isValid, true);
  }

  get addressInput() {
    return this.template.querySelector("lightning-input-address");
  }

  get closeEndDateInput() {
    return this.template.querySelector('lightning-input[data-field="endDate"]');
  }

  /**
   * Purpose: Advances the visible progress steps while the single Apex transaction is running.
   */
  startProgress() {
    this.stopProgress();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.progressTimer = window.setInterval(() => {
      if (this.activeStepIndex < this.currentStepLabels.length - 1) {
        this.completedStepIndex = Math.max(
          this.completedStepIndex,
          this.activeStepIndex - 1
        );
        this.activeStepIndex += 1;
      }
    }, 1200);
  }

  /**
   * Purpose: Stops and clears the progress timer after Apex finishes or fails.
   */
  stopProgress() {
    if (this.progressTimer) {
      window.clearInterval(this.progressTimer);
      this.progressTimer = undefined;
    }
  }

  /**
   * Purpose: Copies Apex step counts into a map so the progress modal can show record totals.
   */
  applyResultSteps(steps) {
    const counts = {};
    const stepLabels = this.currentStepLabels;
    steps.forEach((step) => {
      if (stepLabels.includes(step.name)) {
        counts[step.name] = step.count;
      }
    });
    this.resultStepCounts = counts;
  }

  /**
   * Purpose: Navigates the user to the newly cloned Facility Account after a successful clone.
   */
  navigateToNewFacility(recordId) {
    if (!recordId) {
      return;
    }

    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId,
        objectApiName: "Account",
        actionName: "view"
      }
    });
  }

  /**
   * Purpose: Displays Salesforce toast messages for success and failure states.
   */
  showToast(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title,
        message,
        variant
      })
    );
  }

  /**
   * Purpose: Converts Apex, JavaScript, and LDS-style errors into one readable message for admins and users.
   */
  normalizeError(error) {
    if (Array.isArray(error?.body)) {
      return error.body.map((item) => item.message).join(", ");
    }
    return error?.body?.message ?? error?.message ?? "Unexpected error.";
  }

  /**
   * Purpose: Checks whether the new address contains any user-entered component.
   */
  hasAddressInput() {
    return ADDRESS_FORM_FIELDS.some((field) =>
      `${this.form[field] || ""}`.trim()
    );
  }

  /**
   * Purpose: Displays blank values as Not set so the UI never looks empty.
   */
  displayValue(value) {
    return `${value || ""}`.trim() || "Not set";
  }

  /**
   * Purpose: Displays Account address components as a compact multi-line address.
   */
  displayAddress(source) {
    if (!source) {
      return "Not set";
    }
    const cityState = [source.city, source.state]
      .filter((value) => `${value || ""}`.trim())
      .join(", ");
    const cityLine = [cityState, source.postalCode]
      .filter((value) => `${value || ""}`.trim())
      .join(" ");
    const lines = [source.street, cityLine, source.country].filter((value) =>
      `${value || ""}`.trim()
    );
    return lines.join("\n") || "Not set";
  }

}
