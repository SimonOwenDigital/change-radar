
// ---------------- Type Definitions which can be imported from ./RuntimeTypes -------------------------
export interface TableRegistrations extends BaseTableRegistrations {
    "crdr_signalfingerprint": crdr_signalfingerprint,
    "crdr_signal": crdr_signal,
    "crdr_rule": crdr_rule,
    "crdr_exposure": crdr_exposure,
    "crdr_config": crdr_config,
    "crdr_facetvalue": crdr_facetvalue,
}

export interface EnumRegistrations extends BaseEnumRegistrations {
    "crdr_signalfingerprint-statecode": crdr_signalfingerprint_statecode,
    "crdr_signalfingerprint-statuscode": crdr_signalfingerprint_statuscode,
    "crdr_signalfingerprint-crdr_extractedby": crdr_signalfingerprint_crdr_extractedby,
    "crdr_signalfingerprint-crdr_facet": crdr_signalfingerprint_crdr_facet,
    "crdr_signalfingerprint-crdr_status": crdr_signalfingerprint_crdr_status,
    "crdr_signal-statecode": crdr_signal_statecode,
    "crdr_signal-statuscode": crdr_signal_statuscode,
    "crdr_signal-crdr_actionrequired": crdr_signal_crdr_actionrequired,
    "crdr_signal-crdr_genericimpact": crdr_signal_crdr_genericimpact,
    "crdr_signal-crdr_horizon": crdr_signal_crdr_horizon,
    "crdr_signal-crdr_impacttype": crdr_signal_crdr_impacttype,
    "crdr_signal-crdr_nature": crdr_signal_crdr_nature,
    "crdr_signal-crdr_source": crdr_signal_crdr_source,
    "crdr_rule-statecode": crdr_rule_statecode,
    "crdr_rule-statuscode": crdr_rule_statuscode,
    "crdr_rule-crdr_active": crdr_rule_crdr_active,
    "crdr_rule-crdr_assetfacet": crdr_rule_crdr_assetfacet,
    "crdr_rule-crdr_condition": crdr_rule_crdr_condition,
    "crdr_rule-crdr_role": crdr_rule_crdr_role,
    "crdr_rule-crdr_signalfacet": crdr_rule_crdr_signalfacet,
    "crdr_exposure-statecode": crdr_exposure_statecode,
    "crdr_exposure-statuscode": crdr_exposure_statuscode,
    "crdr_exposure-crdr_source": crdr_exposure_crdr_source,
    "crdr_exposure-crdr_status": crdr_exposure_crdr_status,
    "crdr_config-statecode": crdr_config_statecode,
    "crdr_config-statuscode": crdr_config_statuscode,
    "crdr_facetvalue-statecode": crdr_facetvalue_statecode,
    "crdr_facetvalue-statuscode": crdr_facetvalue_statuscode,
    "crdr_facetvalue-crdr_active": crdr_facetvalue_crdr_active,
    "crdr_facetvalue-crdr_facet": crdr_facetvalue_crdr_facet,
}

export type crdr_signalfingerprint = TableRow<{
    // Primary Key Column
    readonly crdr_signalfingerprintid: string,
    crdr_name: string,
    statecode: crdr_signalfingerprint_statecode,
    statuscode: crdr_signalfingerprint_statuscode,
    crdr_confidence: number,
    crdr_extractedby: crdr_signalfingerprint_crdr_extractedby,
    crdr_facet: crdr_signalfingerprint_crdr_facet,
    crdr_group: string,
    crdr_reason: string,
        // Foreign Key Column
        readonly _crdr_reviewedby_value: `/systemuser(${string})`,
        // Foreign Key Column
    _crdr_signal_value: `/crdr_signal(${string})`,
    crdr_status: crdr_signalfingerprint_crdr_status,
    crdr_value: string,
        // Foreign Key Column
        readonly _organizationid_value: `/organization(${string})`,
}>
export type crdr_signal = TableRow<{
    // Primary Key Column
    readonly crdr_signalid: string,
    crdr_title: string,
    statecode: crdr_signal_statecode,
    statuscode: crdr_signal_statuscode,
    crdr_actionrequired: crdr_signal_crdr_actionrequired,
    crdr_audience: string,
    crdr_confidencelabel: string,
    crdr_datelabel: string,
    crdr_externalid: string,
    crdr_fingerprintedon: Date,
    crdr_firstseen: Date,
    crdr_genericimpact: crdr_signal_crdr_genericimpact,
    crdr_horizon: crdr_signal_crdr_horizon,
    crdr_impacttype: crdr_signal_crdr_impacttype,
    crdr_keydate: Date,
    crdr_lastchanged: Date,
    crdr_nature: crdr_signal_crdr_nature,
    crdr_opportunity: string,
    crdr_products: string,
    crdr_ratedon: Date,
    crdr_ratingconfidence: string,
    crdr_risk: string,
    crdr_source: crdr_signal_crdr_source,
    crdr_summary: string,
    crdr_theme: string,
    crdr_url: string,
        // Foreign Key Column
        readonly _organizationid_value: `/organization(${string})`,
}>
export type crdr_rule = TableRow<{
    // Primary Key Column
    readonly crdr_ruleid: string,
    crdr_name: string,
    statecode: crdr_rule_statecode,
    statuscode: crdr_rule_statuscode,
    crdr_active: crdr_rule_crdr_active,
    crdr_assetfacet: crdr_rule_crdr_assetfacet,
    crdr_condition: crdr_rule_crdr_condition,
    crdr_description: string,
    crdr_role: crdr_rule_crdr_role,
    crdr_rulecode: string,
    crdr_signalfacet: crdr_rule_crdr_signalfacet,
        // Foreign Key Column
        readonly _organizationid_value: `/organization(${string})`,
}>
export type crdr_exposure = TableRow<{
    // Primary Key Column
    readonly crdr_exposureid: string,
    crdr_name: string,
    statecode: crdr_exposure_statecode,
    statuscode: crdr_exposure_statuscode,
        // Foreign Key Column
        readonly _crdr_asset_value: `/crdr_asset(${string})`,
    crdr_evidencetext: string,
    crdr_group: string,
    crdr_matchedfacets: string,
    crdr_rules: string,
        // Foreign Key Column
    _crdr_signal_value: `/crdr_signal(${string})`,
    crdr_source: crdr_exposure_crdr_source,
    crdr_status: crdr_exposure_crdr_status,
        // Foreign Key Column
        readonly _crdr_tenantsetting_value: `/crdr_tenantsetting(${string})`,
        // Foreign Key Column
        readonly _organizationid_value: `/organization(${string})`,
}>
export type crdr_config = TableRow<{
    // Primary Key Column
    readonly crdr_configid: string,
    crdr_key: string,
    statecode: crdr_config_statecode,
    statuscode: crdr_config_statuscode,
    crdr_description: string,
    crdr_value: string,
        // Foreign Key Column
        readonly _organizationid_value: `/organization(${string})`,
}>
export type crdr_facetvalue = TableRow<{
    // Primary Key Column
    readonly crdr_facetvalueid: string,
    crdr_name: string,
    statecode: crdr_facetvalue_statecode,
    statuscode: crdr_facetvalue_statuscode,
    crdr_active: crdr_facetvalue_crdr_active,
    crdr_description: string,
    crdr_facet: crdr_facetvalue_crdr_facet,
    crdr_value: string,
        // Foreign Key Column
        readonly _organizationid_value: `/organization(${string})`,
}>

const enum crdr_signalfingerprint_statecode {
"Active" = 0,
"Inactive" = 1,
}
const enum crdr_signalfingerprint_statuscode {
"Active" = 1,
"Inactive" = 2,
}
const enum crdr_signalfingerprint_crdr_extractedby {
"Rule" = 169890000,
"LLM" = 169890001,
"Manual" = 169890002,
}
const enum crdr_signalfingerprint_crdr_facet {
"Product" = 169890000,
"Resource type" = 169890001,
"Connector" = 169890002,
"Capability" = 169890003,
"Auth mode" = 169890004,
"Harness" = 169890005,
"Setting" = 169890006,
"Environment type" = 169890007,
}
const enum crdr_signalfingerprint_crdr_status {
"Accepted" = 169890000,
"Review" = 169890001,
"Rejected" = 169890002,
}
const enum crdr_signal_statecode {
"Active" = 0,
"Inactive" = 1,
}
const enum crdr_signal_statuscode {
"Active" = 1,
"Inactive" = 2,
}
const enum crdr_signal_crdr_actionrequired {
"No" = 0,
"Yes" = 1,
}
const enum crdr_signal_crdr_genericimpact {
"None" = 169890000,
"Low" = 169890001,
"Medium" = 169890002,
"High" = 169890003,
"Critical" = 169890004,
}
const enum crdr_signal_crdr_horizon {
"Now" = 169890000,
"Imminent" = 169890001,
"Future" = 169890002,
}
const enum crdr_signal_crdr_impacttype {
"Risk" = 169890000,
"Opportunity" = 169890001,
"Risk and opportunity" = 169890002,
}
const enum crdr_signal_crdr_nature {
"Breaking" = 169890000,
"Deprecation" = 169890001,
"Behaviour change" = 169890002,
"New capability" = 169890003,
"Licensing" = 169890004,
"Incident" = 169890005,
"Informational" = 169890006,
}
const enum crdr_signal_crdr_source {
"Message Center (Graph)" = 169890000,
"Service health (Graph)" = 169890001,
"Roadmap" = 169890002,
"Blog" = 169890003,
"Community archive" = 169890004,
"Manual" = 169890005,
}
const enum crdr_rule_statecode {
"Active" = 0,
"Inactive" = 1,
}
const enum crdr_rule_statuscode {
"Active" = 1,
"Inactive" = 2,
}
const enum crdr_rule_crdr_active {
"No" = 0,
"Yes" = 1,
}
const enum crdr_rule_crdr_assetfacet {
"Product" = 169890000,
"Resource type" = 169890001,
"Connector" = 169890002,
"Capability" = 169890003,
"Auth mode" = 169890004,
"Harness" = 169890005,
"Setting" = 169890006,
"Environment type" = 169890007,
}
const enum crdr_rule_crdr_condition {
"Any" = 169890000,
"Setting absent" = 169890001,
}
const enum crdr_rule_crdr_role {
"Scope" = 169890000,
"Trigger" = 169890001,
"Setting" = 169890002,
}
const enum crdr_rule_crdr_signalfacet {
"Product" = 169890000,
"Resource type" = 169890001,
"Connector" = 169890002,
"Capability" = 169890003,
"Auth mode" = 169890004,
"Harness" = 169890005,
"Setting" = 169890006,
"Environment type" = 169890007,
}
const enum crdr_exposure_statecode {
"Active" = 0,
"Inactive" = 1,
}
const enum crdr_exposure_statuscode {
"Active" = 1,
"Inactive" = 2,
}
const enum crdr_exposure_crdr_source {
"Live" = 169890000,
"Fixture" = 169890001,
"Synthetic" = 169890002,
}
const enum crdr_exposure_crdr_status {
"New" = 169890000,
"Confirmed" = 169890001,
"Dismissed" = 169890002,
"No longer matches" = 169890003,
}
const enum crdr_config_statecode {
"Active" = 0,
"Inactive" = 1,
}
const enum crdr_config_statuscode {
"Active" = 1,
"Inactive" = 2,
}
const enum crdr_facetvalue_statecode {
"Active" = 0,
"Inactive" = 1,
}
const enum crdr_facetvalue_statuscode {
"Active" = 1,
"Inactive" = 2,
}
const enum crdr_facetvalue_crdr_active {
"No" = 0,
"Yes" = 1,
}
const enum crdr_facetvalue_crdr_facet {
"Product" = 169890000,
"Resource type" = 169890001,
"Connector" = 169890002,
"Capability" = 169890003,
"Auth mode" = 169890004,
"Harness" = 169890005,
"Setting" = 169890006,
"Environment type" = 169890007,
}


/**
 * Possible scalar values of a data column in a data row.
 */
export type DataColumnValue = string | number | boolean | Date | null;

/**
 * Represents the type for the value of a primary key column, typically a string.
 */
export type RowKeyDataColumnValue = string;

/**
 * Represents the row of a table
 */
export interface DataRow {
  /**
   * A column can be a simple field value
   */
  [column: string]: DataColumnValue;
}

/**
 * Represents a table type with the given row typing
 */
export type TableRow<R extends DataRow = DataRow> = R;

/**
 * Represents a collection of rows for a table
 */
export interface DataTable<T> {
  rows: T[];
  hasMoreRows: boolean;
  loadMoreRows?: () => Promise<DataTable<T>>;
}

// Type equality check utility - leverages assignability of extends
// See https://stackoverflow.com/a/52473108 for detailed explanation
export type IfTypeEquals<X, Y, A, B> = (<T>() => T extends X ? 1 : 2) extends <T>() => T extends Y ? 1 : 2
  ? A
  : B;

export type ExcludeReadonly<T> =
  // For every property, we are checking if a type with just that property (whether readonly or writable) is assignable to a type which requires that property to be writable
  // If it does, then the property is inferred to be writable and is kept in the mapped keys
  // If not, it is removed from the mapped keys
  { [P in keyof T as IfTypeEquals<{ [Q in P]: T[P] }, { -readonly [Q in P]: T[P] }, P, never>]: T[P] };

/**
 * Extracts a sub-type with only the fields of the table (simple values, but not nav props)
 * @template T The original type representing a table row.
 * @template FieldType The base type for fields to extract (defaults to DataColumnValue).
 */
export type ExtractFields<T, FieldType = DataColumnValue> = {
  [K in keyof T as Required<T>[K] extends FieldType ? K : never]: T[K];
};

/**
 * Extracts the properties from type E that represent selectable scalar fields.
 * @template E The entity type.
 */
export type ExtractSelectable<E> = {
  // All simple value fields get included as the actual value
  [K in keyof ExtractFields<E, DataColumnValue>]: E[K];
};

/**
 * Extracts properties representing the OData formatted values for display purposes.
 * Creates properties like `<fieldName>@OData.Community.Display.V1.FormattedValue`.
 * @template E The entity type.
 */
export type ExtractReadonly<E> = {
  // For all field values, include a <prop-name>@OData.Community.Display.V1.FormattedValue string property that holds the formatted value of the field
  [K in keyof ExtractFields<E, DataColumnValue> as `${Extract<
    K,
    string
  >}@OData.Community.Display.V1.FormattedValue`]?: string;
};

/**
 * Retrieved record definition is projected from the defined typing structure for the table
 */
export type ReadableTableRow<E> = ExtractSelectable<E> & ExtractReadonly<E>;

/**
 * Writable record definition is projected from the defined typing structure for the table
 */
export type WritableTableRow<E extends TableRow> = {
  // All non readonly fields get included as the actual value type
  [K in keyof ExcludeReadonly<ExtractFields<E, DataColumnValue>>]: E[K];
};

/**
 * Base options for fetching row data, allowing selection of specific fields.
 * @template E The entity type extending TableRow.
 */
export interface FetchRowOptions<E extends TableRow> {
  /**
   * List of fields to select (not allowed to select from related)
   */
  select?: Array<keyof ExtractSelectable<E>>;
}

/**
 * Options for table query operation
 */
export interface QueryTableOptions<E extends TableRow> extends FetchRowOptions<E> {
  /**
   * Optionally specifies the page size for fetching records
   */
  pageSize?: number;
  /**
   * ODATA filter expression for the table
   */
  filter?: string;

  /**
   * ODATA orderby expression for the table
   */
  orderBy?: string;
}

/**
 * Options for fetching a single record operation
 */
export interface RetrieveRowOptions<E extends TableRow> extends FetchRowOptions<E> {
  /**
   * ID of the row
   */
  id: string;
}

/**
 * Base interface for table registrations. Specific implementations should extend this.
 */
export interface BaseTableRegistrations {
  [tableName: string]: TableRow;
}

/**
 * Base interface for enum registrations. Specific implementations should extend this.
 */
export interface BaseEnumRegistrations {
  [enumName: string]: number;
}

/**
 * Extract all available table names from a given TableRegistrations type
 * @template TR The type extending BaseTableRegistrations.
 * @template E The base entity type constraint (defaults to TableRow).
 */
export type TableName<TR extends BaseTableRegistrations, E extends TableRow = TableRow> = keyof {
  [K in keyof TR as TR[K] extends E ? K : never]: TR[K];
};

/**
 * Extracts all available enum names from a given EnumRegistrations type
 * @template ER The type extending BaseEnumRegistrations.
 */
export type EnumName<ER extends BaseEnumRegistrations> = keyof {
  [K in keyof ER as ER[K] extends number ? K : never]: ER[K];
};

/**
 * Represents a single choice for an enum, containing a display label and its corresponding value.
 * @template E The specific enum name.
 * @template ER The type extending BaseEnumRegistrations.
 */
export interface EnumChoice<E extends EnumName<ER>, ER extends BaseEnumRegistrations> {
  label: string;
  value: ER[E];
}

/**
 * Gets the table row type of a table given its name and optional TableRegistrations type
 * @template T The name of the table.
 * @template TR The type extending BaseTableRegistrations.
 */
export type RowOf<T extends TableName<TR>, TR extends BaseTableRegistrations> = TR[T];

/**
 * The input for a page, which may include an optional record ID, entity name, and additional data.
 */
export interface PageInput {
  recordId?: string;
  entityName?: string;
  data?: object;
}

/**
 * Represents the base interface for a UX Agent Data API, providing CRUD operations for table data
 * and retrieval of enum choices. This generic interface is designed to be extended for specific
 * table and enum registrations.
 *
 * @template TR - The type representing table registrations, mapping table names to their row types.
 * @template ER - The type representing enum registrations, mapping enum names to their value types.
 *
 * @interface
 */
export interface BaseUxAgentDataApi<TR extends BaseTableRegistrations, ER extends BaseEnumRegistrations> {
  /**
   * Creates a new row in the specified table.
   * @template T - The name of the table.
   * @param tableName - The name of the table to create the row in.
   * @param row - The data for the new row.
   * @returns A promise that resolves with the ID of the newly created row.
   */
  createRow<T extends keyof TR>(tableName: T, row: WritableTableRow<TR[T]>): Promise<RowKeyDataColumnValue>;
  /**
   * Updates an existing row in the specified table.
   * @template T - The name of the table.
   * @param tableName - The name of the table containing the row to update.
   * @param rowId - The ID of the row to update.
   * @param row - The updated data for the row.
   * @returns A promise that resolves when the update is complete.
   */
  updateRow<T extends keyof TR>(
    tableName: T,
    rowId: RowKeyDataColumnValue,
    row: WritableTableRow<TR[T]>
  ): Promise<void>;
  /**
   * Deletes a row from the specified table.
   * @template T - The name of the table.
   * @param tableName - The name of the table to delete the row from.
   * @param rowId - The ID of the row to delete.
   * @returns A promise that resolves when the deletion is complete.
   */
  deleteRow<T extends keyof TR>(tableName: T, rowId: RowKeyDataColumnValue): Promise<void>;
  /**
   * Retrieves a single row from the specified table based on the provided options.
   * @template T - The name of the table.
   * @param tableName - The name of the table to retrieve the row from.
   * @param options - The options for retrieving the row, including the row ID and selected fields.
   * @returns A promise that resolves with the retrieved row data.
   */
  retrieveRow<T extends keyof TR>(
    tableName: T,
    options: RetrieveRowOptions<TR[T]>
  ): Promise<ReadableTableRow<TR[T]>>;
  /**
   * Queries a table based on the specified options.
   * @template T - The name of the table.
   * @param tableName - The name of the table to query.
   * @param query - The query options, including select, filter, sorting and pagination settings.
   * @returns A promise that resolves with a DataTable containing the query results.
   */
  queryTable<T extends keyof TR>(
    tableName: T,
    query: QueryTableOptions<TR[T]>
  ): Promise<DataTable<ReadableTableRow<TR[T]>>>;
  /**
   * Retrieves the available choices for a specified enum.
   * @template E - The name of the enum.
   * @param enumName - The name of the enum to retrieve choices for.
   * @returns A promise that resolves with an array of enum choices, each containing a label and value.
   */
  getChoices<E extends EnumName<ER>>(enumName: E): Promise<Array<EnumChoice<E, ER>>>;
}

export interface UxAgentDataApi extends BaseUxAgentDataApi<TableRegistrations, EnumRegistrations> {}

export interface GeneratedComponentProps {
    dataApi: UxAgentDataApi;
    pageInput?: PageInput;
}
