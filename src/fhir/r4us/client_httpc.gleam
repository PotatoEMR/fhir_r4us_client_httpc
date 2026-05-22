////[https://hl7.org/fhir/r4us](https://hl7.org/fhir/r4us) r4us client using httpc

import fhir/r4us/resources
import fhir/r4us/sansio
import fhir/r4us/search_params
import gleam/dynamic/decode.{type Decoder}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// FHIR client for sending http requests to server such as
/// `let pat = resources.patient_read("123", client)`
///
/// create client from server base url with fhirclient_new(baseurl)`
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("r4.smarthealthit.org/")`
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("https://r4.smarthealthit.org/")`
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("https://hapi.fhir.org/baseR4")`
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("127.0.0.1:8000")`
pub type FhirClient =
  sansio.FhirClient

/// creates a new client from server base url
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("r4.smarthealthit.org/")`
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("https://r4.smarthealthit.org/")`
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("https://hapi.fhir.org/baseR4")`
///
/// `let assert Ok(client) = fhirclient_httpc.fhirclient_new("127.0.0.1:8000")`
pub fn fhirclient_new(baseurl: String) -> Result(FhirClient, sansio.ErrBaseUrl) {
  sansio.fhirclient_new(baseurl)
}

pub type Err {
  ErrHttpc(err: httpc.HttpError)
  ErrSansio(err: ErrFromSansio)
}

pub type ErrFromSansio {
  ///got json but could not parse it, probably a missing required field
  ErrParseJson(json.DecodeError)
  ///did not get resource json, often server eg nginx gives basic html response
  ErrNotJson(Response(String))
  ///got operationoutcome error from fhir server
  ErrOperationoutcome(resources.Operationoutcome)
  ///could not make an update or delete request because resource has no id
  ErrNoId
}

fn any_create(
  resource: Json,
  res_type: resources.ResourceType,
  resource_dec: Decoder(r),
  client: FhirClient,
) -> Result(r, Err) {
  let req = sansio.any_create_req(resource, res_type, client)
  sendreq_parseresource(req, resource_dec, res_type)
}

fn any_read(
  id: String,
  client: FhirClient,
  res_type: resources.ResourceType,
  resource_dec: Decoder(a),
) -> Result(a, Err) {
  let req = sansio.any_read_req(id, res_type, client)
  sendreq_parseresource(req, resource_dec, res_type)
}

fn any_update(
  id: Option(String),
  resource: Json,
  res_type: resources.ResourceType,
  res_dec: Decoder(r),
  client: FhirClient,
) -> Result(r, Err) {
  let req = sansio.any_update_req(id, resource, res_type, client)
  case req {
    Ok(req) -> sendreq_parseresource(req, res_dec, res_type)
    Error(_) -> Error(ErrSansio(ErrNoId))
    //can have error preparing update request if resource has no id
  }
}

pub fn any_delete(
  id: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  let req = sansio.any_delete_req(id, res_type, client)
  case httpc.send(req |> request.set_body("")) {
    Error(err) -> Error(ErrHttpc(err))
    Ok(resp) ->
      case sansio.http_or_operationoutcome_resp(resp) {
        Ok(oo_or_http) -> Ok(oo_or_http)
        Error(err) ->
          Error(
            ErrSansio(case err {
              sansio.ErrParseJson(e) -> ErrParseJson(e)
              sansio.ErrNotJson(e) -> ErrNotJson(e)
              sansio.ErrOperationoutcome(e) -> ErrOperationoutcome(e)
            }),
          )
      }
  }
}

/// write out search string manually, in case typed search params don't work
pub fn search_any(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  sansio.any_search_req(search_string, res_type, client)
  |> sendreq_parseresource(resources.bundle_decoder(), resources.RtBundle)
}

/// get all resources in paginated bundle,
/// then stick them all in one bundle and pretend not paginated
///
/// fhirclient_httpc.search_any("name=e&_count=25", "Patient", client) |> fhirclient_httpc.all_pages(client)
pub fn all_pages(
  first_bundle: Result(resources.Bundle, Err),
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  case all_pages_loop(first_bundle, [], client) {
    Error(err) -> Error(err)
    Ok(#(last_bundle, bundles)) -> {
      let entries =
        list.fold(from: [], over: bundles, with: fn(acc, bundle) {
          list.append(bundle.entry, acc)
        })
      Ok(resources.Bundle(..last_bundle, entry: entries, link: []))
    }
  }
}

/// searchs each bundle and returns list
/// also returns last bundle individually
/// because all_pages smushes everything in there
fn all_pages_loop(
  curr_bundle: Result(resources.Bundle, Err),
  acc_bundles: List(resources.Bundle),
  client: FhirClient,
) -> Result(#(resources.Bundle, List(resources.Bundle)), Err) {
  case curr_bundle {
    Error(err) -> Error(err)
    Ok(curr_bundle) -> {
      let acc_bundles = [curr_bundle, ..acc_bundles]
      case sansio.bundle_next_page_req(curr_bundle, client) {
        // Error(_) -> reached last page
        Error(_) -> Ok(#(curr_bundle, acc_bundles))
        Ok(req) -> {
          let next =
            sendreq_parseresource(
              req,
              resources.bundle_decoder(),
              resources.RtBundle,
            )
          all_pages_loop(next, acc_bundles, client)
        }
      }
    }
  }
}

pub fn all_pages_forgiving(
  first_bundle: Result(resources.BundleForgiving, Err),
  client: FhirClient,
) -> Result(resources.BundleForgiving, Err) {
  case all_pages_loop_forgiving(first_bundle, [], client) {
    Error(err) -> Error(err)
    Ok(#(last_bundle, bundles)) -> {
      let entries =
        list.fold(from: [], over: bundles, with: fn(acc, bundle) {
          list.append(bundle.entry, acc)
        })
      Ok(resources.BundleForgiving(..last_bundle, entry: entries, link: []))
    }
  }
}

// arguably very duplicated, maybe should be combined somehow
fn all_pages_loop_forgiving(
  curr_bundle: Result(resources.BundleForgiving, Err),
  acc_bundles: List(resources.BundleForgiving),
  client: FhirClient,
) -> Result(#(resources.BundleForgiving, List(resources.BundleForgiving)), Err) {
  case curr_bundle {
    Error(err) -> Error(err)
    Ok(curr_bundle) -> {
      let acc_bundles = [curr_bundle, ..acc_bundles]
      case sansio.bundle_next_page_req_forgiving(curr_bundle, client) {
        // Error(_) -> reached last page
        Error(_) -> Ok(#(curr_bundle, acc_bundles))
        Ok(req) -> {
          let next =
            sendreq_parseresource(
              req,
              resources.bundle_decoder_forgiving(),
              resources.RtBundle,
            )
          all_pages_loop_forgiving(next, acc_bundles, client)
        }
      }
    }
  }
}

/// instead of failing whole decoder on bundle entry with invalid resource,
/// return valid resources alongside list of errors
pub fn search_any_forgiving(
  search_string: String,
  res_type: resources.ResourceType,
  client: FhirClient,
) -> Result(resources.BundleForgiving, Err) {
  sansio.any_search_req(search_string, res_type, client)
  |> sendreq_parseresource(
    resources.bundle_decoder_forgiving(),
    resources.RtBundle,
  )
}

/// run any operation string on any resource type, optionally using Parameters
pub fn operation_any(
  params params: Option(resources.Parameters),
  operation_name operation_name: String,
  res_type res_type: resources.ResourceType,
  res_id res_id: Option(String),
  res_decoder res_decoder: Decoder(res),
  return_res_type return_res_type: resources.ResourceType,
  client client: FhirClient,
) -> Result(res, Err) {
  let req =
    sansio.any_operation_req(res_type, res_id, operation_name, params, client)
  sendreq_parseresource(req, res_decoder, return_res_type)
}

pub fn batch(
  reqs: List(Request(Option(Json))),
  bundle_type: sansio.PostBundleType,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  let req = sansio.batch_req(reqs, bundle_type, client)
  sendreq_parseresource(req, resources.bundle_decoder(), resources.RtBundle)
}

fn sendreq_parseresource(
  req: Request(Option(Json)),
  res_dec: Decoder(r),
  res_type: resources.ResourceType,
) -> Result(r, Err) {
  case
    req
    |> request.set_body(case req.body {
      None -> ""
      Some(body) -> json.to_string(body)
    })
    |> httpc.send
  {
    Error(err) -> Error(ErrHttpc(err))
    Ok(resp) ->
      case sansio.any_resp(resp, res_dec, res_type) {
        Ok(resource) -> Ok(resource)
        Error(err) ->
          Error(
            ErrSansio(case err {
              sansio.ErrParseJson(e) -> ErrParseJson(e)
              sansio.ErrNotJson(e) -> ErrNotJson(e)
              sansio.ErrOperationoutcome(e) -> ErrOperationoutcome(e)
            }),
          )
      }
  }
}

pub fn account_create(
  resource: resources.Account,
  client: FhirClient,
) -> Result(resources.Account, Err) {
  any_create(
    resources.account_to_json(resource),
    resources.RtAccount,
    resources.account_decoder(),
    client,
  )
}

pub fn account_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Account, Err) {
  any_read(id, client, resources.RtAccount, resources.account_decoder())
}

pub fn account_update(
  resource: resources.Account,
  client: FhirClient,
) -> Result(resources.Account, Err) {
  any_update(
    resource.id,
    resources.account_to_json(resource),
    resources.RtAccount,
    resources.account_decoder(),
    client,
  )
}

pub fn account_delete(
  resource: resources.Account,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtAccount, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn activitydefinition_create(
  resource: resources.Activitydefinition,
  client: FhirClient,
) -> Result(resources.Activitydefinition, Err) {
  any_create(
    resources.activitydefinition_to_json(resource),
    resources.RtActivitydefinition,
    resources.activitydefinition_decoder(),
    client,
  )
}

pub fn activitydefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Activitydefinition, Err) {
  any_read(
    id,
    client,
    resources.RtActivitydefinition,
    resources.activitydefinition_decoder(),
  )
}

pub fn activitydefinition_update(
  resource: resources.Activitydefinition,
  client: FhirClient,
) -> Result(resources.Activitydefinition, Err) {
  any_update(
    resource.id,
    resources.activitydefinition_to_json(resource),
    resources.RtActivitydefinition,
    resources.activitydefinition_decoder(),
    client,
  )
}

pub fn activitydefinition_delete(
  resource: resources.Activitydefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtActivitydefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn adverseevent_create(
  resource: resources.Adverseevent,
  client: FhirClient,
) -> Result(resources.Adverseevent, Err) {
  any_create(
    resources.adverseevent_to_json(resource),
    resources.RtAdverseevent,
    resources.adverseevent_decoder(),
    client,
  )
}

pub fn adverseevent_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Adverseevent, Err) {
  any_read(
    id,
    client,
    resources.RtAdverseevent,
    resources.adverseevent_decoder(),
  )
}

pub fn adverseevent_update(
  resource: resources.Adverseevent,
  client: FhirClient,
) -> Result(resources.Adverseevent, Err) {
  any_update(
    resource.id,
    resources.adverseevent_to_json(resource),
    resources.RtAdverseevent,
    resources.adverseevent_decoder(),
    client,
  )
}

pub fn adverseevent_delete(
  resource: resources.Adverseevent,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtAdverseevent, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn allergyintolerance_create(
  resource: resources.Allergyintolerance,
  client: FhirClient,
) -> Result(resources.Allergyintolerance, Err) {
  any_create(
    resources.allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.allergyintolerance_decoder(),
    client,
  )
}

pub fn allergyintolerance_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Allergyintolerance, Err) {
  any_read(
    id,
    client,
    resources.RtAllergyintolerance,
    resources.allergyintolerance_decoder(),
  )
}

pub fn allergyintolerance_update(
  resource: resources.Allergyintolerance,
  client: FhirClient,
) -> Result(resources.Allergyintolerance, Err) {
  any_update(
    resource.id,
    resources.allergyintolerance_to_json(resource),
    resources.RtAllergyintolerance,
    resources.allergyintolerance_decoder(),
    client,
  )
}

pub fn allergyintolerance_delete(
  resource: resources.Allergyintolerance,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtAllergyintolerance, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn appointment_create(
  resource: resources.Appointment,
  client: FhirClient,
) -> Result(resources.Appointment, Err) {
  any_create(
    resources.appointment_to_json(resource),
    resources.RtAppointment,
    resources.appointment_decoder(),
    client,
  )
}

pub fn appointment_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Appointment, Err) {
  any_read(id, client, resources.RtAppointment, resources.appointment_decoder())
}

pub fn appointment_update(
  resource: resources.Appointment,
  client: FhirClient,
) -> Result(resources.Appointment, Err) {
  any_update(
    resource.id,
    resources.appointment_to_json(resource),
    resources.RtAppointment,
    resources.appointment_decoder(),
    client,
  )
}

pub fn appointment_delete(
  resource: resources.Appointment,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtAppointment, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn appointmentresponse_create(
  resource: resources.Appointmentresponse,
  client: FhirClient,
) -> Result(resources.Appointmentresponse, Err) {
  any_create(
    resources.appointmentresponse_to_json(resource),
    resources.RtAppointmentresponse,
    resources.appointmentresponse_decoder(),
    client,
  )
}

pub fn appointmentresponse_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Appointmentresponse, Err) {
  any_read(
    id,
    client,
    resources.RtAppointmentresponse,
    resources.appointmentresponse_decoder(),
  )
}

pub fn appointmentresponse_update(
  resource: resources.Appointmentresponse,
  client: FhirClient,
) -> Result(resources.Appointmentresponse, Err) {
  any_update(
    resource.id,
    resources.appointmentresponse_to_json(resource),
    resources.RtAppointmentresponse,
    resources.appointmentresponse_decoder(),
    client,
  )
}

pub fn appointmentresponse_delete(
  resource: resources.Appointmentresponse,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtAppointmentresponse, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn auditevent_create(
  resource: resources.Auditevent,
  client: FhirClient,
) -> Result(resources.Auditevent, Err) {
  any_create(
    resources.auditevent_to_json(resource),
    resources.RtAuditevent,
    resources.auditevent_decoder(),
    client,
  )
}

pub fn auditevent_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Auditevent, Err) {
  any_read(id, client, resources.RtAuditevent, resources.auditevent_decoder())
}

pub fn auditevent_update(
  resource: resources.Auditevent,
  client: FhirClient,
) -> Result(resources.Auditevent, Err) {
  any_update(
    resource.id,
    resources.auditevent_to_json(resource),
    resources.RtAuditevent,
    resources.auditevent_decoder(),
    client,
  )
}

pub fn auditevent_delete(
  resource: resources.Auditevent,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtAuditevent, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn basic_create(
  resource: resources.Basic,
  client: FhirClient,
) -> Result(resources.Basic, Err) {
  any_create(
    resources.basic_to_json(resource),
    resources.RtBasic,
    resources.basic_decoder(),
    client,
  )
}

pub fn basic_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Basic, Err) {
  any_read(id, client, resources.RtBasic, resources.basic_decoder())
}

pub fn basic_update(
  resource: resources.Basic,
  client: FhirClient,
) -> Result(resources.Basic, Err) {
  any_update(
    resource.id,
    resources.basic_to_json(resource),
    resources.RtBasic,
    resources.basic_decoder(),
    client,
  )
}

pub fn basic_delete(
  resource: resources.Basic,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtBasic, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn binary_create(
  resource: resources.Binary,
  client: FhirClient,
) -> Result(resources.Binary, Err) {
  any_create(
    resources.binary_to_json(resource),
    resources.RtBinary,
    resources.binary_decoder(),
    client,
  )
}

pub fn binary_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Binary, Err) {
  any_read(id, client, resources.RtBinary, resources.binary_decoder())
}

pub fn binary_update(
  resource: resources.Binary,
  client: FhirClient,
) -> Result(resources.Binary, Err) {
  any_update(
    resource.id,
    resources.binary_to_json(resource),
    resources.RtBinary,
    resources.binary_decoder(),
    client,
  )
}

pub fn binary_delete(
  resource: resources.Binary,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtBinary, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn biologicallyderivedproduct_create(
  resource: resources.Biologicallyderivedproduct,
  client: FhirClient,
) -> Result(resources.Biologicallyderivedproduct, Err) {
  any_create(
    resources.biologicallyderivedproduct_to_json(resource),
    resources.RtBiologicallyderivedproduct,
    resources.biologicallyderivedproduct_decoder(),
    client,
  )
}

pub fn biologicallyderivedproduct_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Biologicallyderivedproduct, Err) {
  any_read(
    id,
    client,
    resources.RtBiologicallyderivedproduct,
    resources.biologicallyderivedproduct_decoder(),
  )
}

pub fn biologicallyderivedproduct_update(
  resource: resources.Biologicallyderivedproduct,
  client: FhirClient,
) -> Result(resources.Biologicallyderivedproduct, Err) {
  any_update(
    resource.id,
    resources.biologicallyderivedproduct_to_json(resource),
    resources.RtBiologicallyderivedproduct,
    resources.biologicallyderivedproduct_decoder(),
    client,
  )
}

pub fn biologicallyderivedproduct_delete(
  resource: resources.Biologicallyderivedproduct,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtBiologicallyderivedproduct, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn bodystructure_create(
  resource: resources.Bodystructure,
  client: FhirClient,
) -> Result(resources.Bodystructure, Err) {
  any_create(
    resources.bodystructure_to_json(resource),
    resources.RtBodystructure,
    resources.bodystructure_decoder(),
    client,
  )
}

pub fn bodystructure_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Bodystructure, Err) {
  any_read(
    id,
    client,
    resources.RtBodystructure,
    resources.bodystructure_decoder(),
  )
}

pub fn bodystructure_update(
  resource: resources.Bodystructure,
  client: FhirClient,
) -> Result(resources.Bodystructure, Err) {
  any_update(
    resource.id,
    resources.bodystructure_to_json(resource),
    resources.RtBodystructure,
    resources.bodystructure_decoder(),
    client,
  )
}

pub fn bodystructure_delete(
  resource: resources.Bodystructure,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtBodystructure, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn bundle_create(
  resource: resources.Bundle,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  any_create(
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
  )
}

pub fn bundle_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  any_read(id, client, resources.RtBundle, resources.bundle_decoder())
}

pub fn bundle_update(
  resource: resources.Bundle,
  client: FhirClient,
) -> Result(resources.Bundle, Err) {
  any_update(
    resource.id,
    resources.bundle_to_json(resource),
    resources.RtBundle,
    resources.bundle_decoder(),
    client,
  )
}

pub fn bundle_delete(
  resource: resources.Bundle,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtBundle, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn capabilitystatement_create(
  resource: resources.Capabilitystatement,
  client: FhirClient,
) -> Result(resources.Capabilitystatement, Err) {
  any_create(
    resources.capabilitystatement_to_json(resource),
    resources.RtCapabilitystatement,
    resources.capabilitystatement_decoder(),
    client,
  )
}

pub fn capabilitystatement_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Capabilitystatement, Err) {
  any_read(
    id,
    client,
    resources.RtCapabilitystatement,
    resources.capabilitystatement_decoder(),
  )
}

pub fn capabilitystatement_update(
  resource: resources.Capabilitystatement,
  client: FhirClient,
) -> Result(resources.Capabilitystatement, Err) {
  any_update(
    resource.id,
    resources.capabilitystatement_to_json(resource),
    resources.RtCapabilitystatement,
    resources.capabilitystatement_decoder(),
    client,
  )
}

pub fn capabilitystatement_delete(
  resource: resources.Capabilitystatement,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCapabilitystatement, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn careplan_create(
  resource: resources.Careplan,
  client: FhirClient,
) -> Result(resources.Careplan, Err) {
  any_create(
    resources.careplan_to_json(resource),
    resources.RtCareplan,
    resources.careplan_decoder(),
    client,
  )
}

pub fn careplan_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Careplan, Err) {
  any_read(id, client, resources.RtCareplan, resources.careplan_decoder())
}

pub fn careplan_update(
  resource: resources.Careplan,
  client: FhirClient,
) -> Result(resources.Careplan, Err) {
  any_update(
    resource.id,
    resources.careplan_to_json(resource),
    resources.RtCareplan,
    resources.careplan_decoder(),
    client,
  )
}

pub fn careplan_delete(
  resource: resources.Careplan,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCareplan, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn careteam_create(
  resource: resources.Careteam,
  client: FhirClient,
) -> Result(resources.Careteam, Err) {
  any_create(
    resources.careteam_to_json(resource),
    resources.RtCareteam,
    resources.careteam_decoder(),
    client,
  )
}

pub fn careteam_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Careteam, Err) {
  any_read(id, client, resources.RtCareteam, resources.careteam_decoder())
}

pub fn careteam_update(
  resource: resources.Careteam,
  client: FhirClient,
) -> Result(resources.Careteam, Err) {
  any_update(
    resource.id,
    resources.careteam_to_json(resource),
    resources.RtCareteam,
    resources.careteam_decoder(),
    client,
  )
}

pub fn careteam_delete(
  resource: resources.Careteam,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCareteam, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn catalogentry_create(
  resource: resources.Catalogentry,
  client: FhirClient,
) -> Result(resources.Catalogentry, Err) {
  any_create(
    resources.catalogentry_to_json(resource),
    resources.RtCatalogentry,
    resources.catalogentry_decoder(),
    client,
  )
}

pub fn catalogentry_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Catalogentry, Err) {
  any_read(
    id,
    client,
    resources.RtCatalogentry,
    resources.catalogentry_decoder(),
  )
}

pub fn catalogentry_update(
  resource: resources.Catalogentry,
  client: FhirClient,
) -> Result(resources.Catalogentry, Err) {
  any_update(
    resource.id,
    resources.catalogentry_to_json(resource),
    resources.RtCatalogentry,
    resources.catalogentry_decoder(),
    client,
  )
}

pub fn catalogentry_delete(
  resource: resources.Catalogentry,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCatalogentry, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn chargeitem_create(
  resource: resources.Chargeitem,
  client: FhirClient,
) -> Result(resources.Chargeitem, Err) {
  any_create(
    resources.chargeitem_to_json(resource),
    resources.RtChargeitem,
    resources.chargeitem_decoder(),
    client,
  )
}

pub fn chargeitem_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Chargeitem, Err) {
  any_read(id, client, resources.RtChargeitem, resources.chargeitem_decoder())
}

pub fn chargeitem_update(
  resource: resources.Chargeitem,
  client: FhirClient,
) -> Result(resources.Chargeitem, Err) {
  any_update(
    resource.id,
    resources.chargeitem_to_json(resource),
    resources.RtChargeitem,
    resources.chargeitem_decoder(),
    client,
  )
}

pub fn chargeitem_delete(
  resource: resources.Chargeitem,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtChargeitem, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn chargeitemdefinition_create(
  resource: resources.Chargeitemdefinition,
  client: FhirClient,
) -> Result(resources.Chargeitemdefinition, Err) {
  any_create(
    resources.chargeitemdefinition_to_json(resource),
    resources.RtChargeitemdefinition,
    resources.chargeitemdefinition_decoder(),
    client,
  )
}

pub fn chargeitemdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Chargeitemdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtChargeitemdefinition,
    resources.chargeitemdefinition_decoder(),
  )
}

pub fn chargeitemdefinition_update(
  resource: resources.Chargeitemdefinition,
  client: FhirClient,
) -> Result(resources.Chargeitemdefinition, Err) {
  any_update(
    resource.id,
    resources.chargeitemdefinition_to_json(resource),
    resources.RtChargeitemdefinition,
    resources.chargeitemdefinition_decoder(),
    client,
  )
}

pub fn chargeitemdefinition_delete(
  resource: resources.Chargeitemdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtChargeitemdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn claim_create(
  resource: resources.Claim,
  client: FhirClient,
) -> Result(resources.Claim, Err) {
  any_create(
    resources.claim_to_json(resource),
    resources.RtClaim,
    resources.claim_decoder(),
    client,
  )
}

pub fn claim_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Claim, Err) {
  any_read(id, client, resources.RtClaim, resources.claim_decoder())
}

pub fn claim_update(
  resource: resources.Claim,
  client: FhirClient,
) -> Result(resources.Claim, Err) {
  any_update(
    resource.id,
    resources.claim_to_json(resource),
    resources.RtClaim,
    resources.claim_decoder(),
    client,
  )
}

pub fn claim_delete(
  resource: resources.Claim,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtClaim, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn claimresponse_create(
  resource: resources.Claimresponse,
  client: FhirClient,
) -> Result(resources.Claimresponse, Err) {
  any_create(
    resources.claimresponse_to_json(resource),
    resources.RtClaimresponse,
    resources.claimresponse_decoder(),
    client,
  )
}

pub fn claimresponse_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Claimresponse, Err) {
  any_read(
    id,
    client,
    resources.RtClaimresponse,
    resources.claimresponse_decoder(),
  )
}

pub fn claimresponse_update(
  resource: resources.Claimresponse,
  client: FhirClient,
) -> Result(resources.Claimresponse, Err) {
  any_update(
    resource.id,
    resources.claimresponse_to_json(resource),
    resources.RtClaimresponse,
    resources.claimresponse_decoder(),
    client,
  )
}

pub fn claimresponse_delete(
  resource: resources.Claimresponse,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtClaimresponse, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn clinicalimpression_create(
  resource: resources.Clinicalimpression,
  client: FhirClient,
) -> Result(resources.Clinicalimpression, Err) {
  any_create(
    resources.clinicalimpression_to_json(resource),
    resources.RtClinicalimpression,
    resources.clinicalimpression_decoder(),
    client,
  )
}

pub fn clinicalimpression_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Clinicalimpression, Err) {
  any_read(
    id,
    client,
    resources.RtClinicalimpression,
    resources.clinicalimpression_decoder(),
  )
}

pub fn clinicalimpression_update(
  resource: resources.Clinicalimpression,
  client: FhirClient,
) -> Result(resources.Clinicalimpression, Err) {
  any_update(
    resource.id,
    resources.clinicalimpression_to_json(resource),
    resources.RtClinicalimpression,
    resources.clinicalimpression_decoder(),
    client,
  )
}

pub fn clinicalimpression_delete(
  resource: resources.Clinicalimpression,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtClinicalimpression, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn codesystem_create(
  resource: resources.Codesystem,
  client: FhirClient,
) -> Result(resources.Codesystem, Err) {
  any_create(
    resources.codesystem_to_json(resource),
    resources.RtCodesystem,
    resources.codesystem_decoder(),
    client,
  )
}

pub fn codesystem_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Codesystem, Err) {
  any_read(id, client, resources.RtCodesystem, resources.codesystem_decoder())
}

pub fn codesystem_update(
  resource: resources.Codesystem,
  client: FhirClient,
) -> Result(resources.Codesystem, Err) {
  any_update(
    resource.id,
    resources.codesystem_to_json(resource),
    resources.RtCodesystem,
    resources.codesystem_decoder(),
    client,
  )
}

pub fn codesystem_delete(
  resource: resources.Codesystem,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCodesystem, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn communication_create(
  resource: resources.Communication,
  client: FhirClient,
) -> Result(resources.Communication, Err) {
  any_create(
    resources.communication_to_json(resource),
    resources.RtCommunication,
    resources.communication_decoder(),
    client,
  )
}

pub fn communication_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Communication, Err) {
  any_read(
    id,
    client,
    resources.RtCommunication,
    resources.communication_decoder(),
  )
}

pub fn communication_update(
  resource: resources.Communication,
  client: FhirClient,
) -> Result(resources.Communication, Err) {
  any_update(
    resource.id,
    resources.communication_to_json(resource),
    resources.RtCommunication,
    resources.communication_decoder(),
    client,
  )
}

pub fn communication_delete(
  resource: resources.Communication,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCommunication, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn communicationrequest_create(
  resource: resources.Communicationrequest,
  client: FhirClient,
) -> Result(resources.Communicationrequest, Err) {
  any_create(
    resources.communicationrequest_to_json(resource),
    resources.RtCommunicationrequest,
    resources.communicationrequest_decoder(),
    client,
  )
}

pub fn communicationrequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Communicationrequest, Err) {
  any_read(
    id,
    client,
    resources.RtCommunicationrequest,
    resources.communicationrequest_decoder(),
  )
}

pub fn communicationrequest_update(
  resource: resources.Communicationrequest,
  client: FhirClient,
) -> Result(resources.Communicationrequest, Err) {
  any_update(
    resource.id,
    resources.communicationrequest_to_json(resource),
    resources.RtCommunicationrequest,
    resources.communicationrequest_decoder(),
    client,
  )
}

pub fn communicationrequest_delete(
  resource: resources.Communicationrequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCommunicationrequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn compartmentdefinition_create(
  resource: resources.Compartmentdefinition,
  client: FhirClient,
) -> Result(resources.Compartmentdefinition, Err) {
  any_create(
    resources.compartmentdefinition_to_json(resource),
    resources.RtCompartmentdefinition,
    resources.compartmentdefinition_decoder(),
    client,
  )
}

pub fn compartmentdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Compartmentdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtCompartmentdefinition,
    resources.compartmentdefinition_decoder(),
  )
}

pub fn compartmentdefinition_update(
  resource: resources.Compartmentdefinition,
  client: FhirClient,
) -> Result(resources.Compartmentdefinition, Err) {
  any_update(
    resource.id,
    resources.compartmentdefinition_to_json(resource),
    resources.RtCompartmentdefinition,
    resources.compartmentdefinition_decoder(),
    client,
  )
}

pub fn compartmentdefinition_delete(
  resource: resources.Compartmentdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCompartmentdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn composition_create(
  resource: resources.Composition,
  client: FhirClient,
) -> Result(resources.Composition, Err) {
  any_create(
    resources.composition_to_json(resource),
    resources.RtComposition,
    resources.composition_decoder(),
    client,
  )
}

pub fn composition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Composition, Err) {
  any_read(id, client, resources.RtComposition, resources.composition_decoder())
}

pub fn composition_update(
  resource: resources.Composition,
  client: FhirClient,
) -> Result(resources.Composition, Err) {
  any_update(
    resource.id,
    resources.composition_to_json(resource),
    resources.RtComposition,
    resources.composition_decoder(),
    client,
  )
}

pub fn composition_delete(
  resource: resources.Composition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtComposition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn conceptmap_create(
  resource: resources.Conceptmap,
  client: FhirClient,
) -> Result(resources.Conceptmap, Err) {
  any_create(
    resources.conceptmap_to_json(resource),
    resources.RtConceptmap,
    resources.conceptmap_decoder(),
    client,
  )
}

pub fn conceptmap_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Conceptmap, Err) {
  any_read(id, client, resources.RtConceptmap, resources.conceptmap_decoder())
}

pub fn conceptmap_update(
  resource: resources.Conceptmap,
  client: FhirClient,
) -> Result(resources.Conceptmap, Err) {
  any_update(
    resource.id,
    resources.conceptmap_to_json(resource),
    resources.RtConceptmap,
    resources.conceptmap_decoder(),
    client,
  )
}

pub fn conceptmap_delete(
  resource: resources.Conceptmap,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtConceptmap, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn condition_create(
  resource: resources.Condition,
  client: FhirClient,
) -> Result(resources.Condition, Err) {
  any_create(
    resources.condition_to_json(resource),
    resources.RtCondition,
    resources.condition_decoder(),
    client,
  )
}

pub fn condition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Condition, Err) {
  any_read(id, client, resources.RtCondition, resources.condition_decoder())
}

pub fn condition_update(
  resource: resources.Condition,
  client: FhirClient,
) -> Result(resources.Condition, Err) {
  any_update(
    resource.id,
    resources.condition_to_json(resource),
    resources.RtCondition,
    resources.condition_decoder(),
    client,
  )
}

pub fn condition_delete(
  resource: resources.Condition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCondition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn consent_create(
  resource: resources.Consent,
  client: FhirClient,
) -> Result(resources.Consent, Err) {
  any_create(
    resources.consent_to_json(resource),
    resources.RtConsent,
    resources.consent_decoder(),
    client,
  )
}

pub fn consent_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Consent, Err) {
  any_read(id, client, resources.RtConsent, resources.consent_decoder())
}

pub fn consent_update(
  resource: resources.Consent,
  client: FhirClient,
) -> Result(resources.Consent, Err) {
  any_update(
    resource.id,
    resources.consent_to_json(resource),
    resources.RtConsent,
    resources.consent_decoder(),
    client,
  )
}

pub fn consent_delete(
  resource: resources.Consent,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtConsent, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn contract_create(
  resource: resources.Contract,
  client: FhirClient,
) -> Result(resources.Contract, Err) {
  any_create(
    resources.contract_to_json(resource),
    resources.RtContract,
    resources.contract_decoder(),
    client,
  )
}

pub fn contract_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Contract, Err) {
  any_read(id, client, resources.RtContract, resources.contract_decoder())
}

pub fn contract_update(
  resource: resources.Contract,
  client: FhirClient,
) -> Result(resources.Contract, Err) {
  any_update(
    resource.id,
    resources.contract_to_json(resource),
    resources.RtContract,
    resources.contract_decoder(),
    client,
  )
}

pub fn contract_delete(
  resource: resources.Contract,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtContract, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn coverage_create(
  resource: resources.Coverage,
  client: FhirClient,
) -> Result(resources.Coverage, Err) {
  any_create(
    resources.coverage_to_json(resource),
    resources.RtCoverage,
    resources.coverage_decoder(),
    client,
  )
}

pub fn coverage_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Coverage, Err) {
  any_read(id, client, resources.RtCoverage, resources.coverage_decoder())
}

pub fn coverage_update(
  resource: resources.Coverage,
  client: FhirClient,
) -> Result(resources.Coverage, Err) {
  any_update(
    resource.id,
    resources.coverage_to_json(resource),
    resources.RtCoverage,
    resources.coverage_decoder(),
    client,
  )
}

pub fn coverage_delete(
  resource: resources.Coverage,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCoverage, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn coverageeligibilityrequest_create(
  resource: resources.Coverageeligibilityrequest,
  client: FhirClient,
) -> Result(resources.Coverageeligibilityrequest, Err) {
  any_create(
    resources.coverageeligibilityrequest_to_json(resource),
    resources.RtCoverageeligibilityrequest,
    resources.coverageeligibilityrequest_decoder(),
    client,
  )
}

pub fn coverageeligibilityrequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Coverageeligibilityrequest, Err) {
  any_read(
    id,
    client,
    resources.RtCoverageeligibilityrequest,
    resources.coverageeligibilityrequest_decoder(),
  )
}

pub fn coverageeligibilityrequest_update(
  resource: resources.Coverageeligibilityrequest,
  client: FhirClient,
) -> Result(resources.Coverageeligibilityrequest, Err) {
  any_update(
    resource.id,
    resources.coverageeligibilityrequest_to_json(resource),
    resources.RtCoverageeligibilityrequest,
    resources.coverageeligibilityrequest_decoder(),
    client,
  )
}

pub fn coverageeligibilityrequest_delete(
  resource: resources.Coverageeligibilityrequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCoverageeligibilityrequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn coverageeligibilityresponse_create(
  resource: resources.Coverageeligibilityresponse,
  client: FhirClient,
) -> Result(resources.Coverageeligibilityresponse, Err) {
  any_create(
    resources.coverageeligibilityresponse_to_json(resource),
    resources.RtCoverageeligibilityresponse,
    resources.coverageeligibilityresponse_decoder(),
    client,
  )
}

pub fn coverageeligibilityresponse_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Coverageeligibilityresponse, Err) {
  any_read(
    id,
    client,
    resources.RtCoverageeligibilityresponse,
    resources.coverageeligibilityresponse_decoder(),
  )
}

pub fn coverageeligibilityresponse_update(
  resource: resources.Coverageeligibilityresponse,
  client: FhirClient,
) -> Result(resources.Coverageeligibilityresponse, Err) {
  any_update(
    resource.id,
    resources.coverageeligibilityresponse_to_json(resource),
    resources.RtCoverageeligibilityresponse,
    resources.coverageeligibilityresponse_decoder(),
    client,
  )
}

pub fn coverageeligibilityresponse_delete(
  resource: resources.Coverageeligibilityresponse,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtCoverageeligibilityresponse, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn detectedissue_create(
  resource: resources.Detectedissue,
  client: FhirClient,
) -> Result(resources.Detectedissue, Err) {
  any_create(
    resources.detectedissue_to_json(resource),
    resources.RtDetectedissue,
    resources.detectedissue_decoder(),
    client,
  )
}

pub fn detectedissue_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Detectedissue, Err) {
  any_read(
    id,
    client,
    resources.RtDetectedissue,
    resources.detectedissue_decoder(),
  )
}

pub fn detectedissue_update(
  resource: resources.Detectedissue,
  client: FhirClient,
) -> Result(resources.Detectedissue, Err) {
  any_update(
    resource.id,
    resources.detectedissue_to_json(resource),
    resources.RtDetectedissue,
    resources.detectedissue_decoder(),
    client,
  )
}

pub fn detectedissue_delete(
  resource: resources.Detectedissue,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDetectedissue, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn device_create(
  resource: resources.Device,
  client: FhirClient,
) -> Result(resources.Device, Err) {
  any_create(
    resources.device_to_json(resource),
    resources.RtDevice,
    resources.device_decoder(),
    client,
  )
}

pub fn device_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Device, Err) {
  any_read(id, client, resources.RtDevice, resources.device_decoder())
}

pub fn device_update(
  resource: resources.Device,
  client: FhirClient,
) -> Result(resources.Device, Err) {
  any_update(
    resource.id,
    resources.device_to_json(resource),
    resources.RtDevice,
    resources.device_decoder(),
    client,
  )
}

pub fn device_delete(
  resource: resources.Device,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDevice, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn devicedefinition_create(
  resource: resources.Devicedefinition,
  client: FhirClient,
) -> Result(resources.Devicedefinition, Err) {
  any_create(
    resources.devicedefinition_to_json(resource),
    resources.RtDevicedefinition,
    resources.devicedefinition_decoder(),
    client,
  )
}

pub fn devicedefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Devicedefinition, Err) {
  any_read(
    id,
    client,
    resources.RtDevicedefinition,
    resources.devicedefinition_decoder(),
  )
}

pub fn devicedefinition_update(
  resource: resources.Devicedefinition,
  client: FhirClient,
) -> Result(resources.Devicedefinition, Err) {
  any_update(
    resource.id,
    resources.devicedefinition_to_json(resource),
    resources.RtDevicedefinition,
    resources.devicedefinition_decoder(),
    client,
  )
}

pub fn devicedefinition_delete(
  resource: resources.Devicedefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDevicedefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn devicemetric_create(
  resource: resources.Devicemetric,
  client: FhirClient,
) -> Result(resources.Devicemetric, Err) {
  any_create(
    resources.devicemetric_to_json(resource),
    resources.RtDevicemetric,
    resources.devicemetric_decoder(),
    client,
  )
}

pub fn devicemetric_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Devicemetric, Err) {
  any_read(
    id,
    client,
    resources.RtDevicemetric,
    resources.devicemetric_decoder(),
  )
}

pub fn devicemetric_update(
  resource: resources.Devicemetric,
  client: FhirClient,
) -> Result(resources.Devicemetric, Err) {
  any_update(
    resource.id,
    resources.devicemetric_to_json(resource),
    resources.RtDevicemetric,
    resources.devicemetric_decoder(),
    client,
  )
}

pub fn devicemetric_delete(
  resource: resources.Devicemetric,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDevicemetric, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn devicerequest_create(
  resource: resources.Devicerequest,
  client: FhirClient,
) -> Result(resources.Devicerequest, Err) {
  any_create(
    resources.devicerequest_to_json(resource),
    resources.RtDevicerequest,
    resources.devicerequest_decoder(),
    client,
  )
}

pub fn devicerequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Devicerequest, Err) {
  any_read(
    id,
    client,
    resources.RtDevicerequest,
    resources.devicerequest_decoder(),
  )
}

pub fn devicerequest_update(
  resource: resources.Devicerequest,
  client: FhirClient,
) -> Result(resources.Devicerequest, Err) {
  any_update(
    resource.id,
    resources.devicerequest_to_json(resource),
    resources.RtDevicerequest,
    resources.devicerequest_decoder(),
    client,
  )
}

pub fn devicerequest_delete(
  resource: resources.Devicerequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDevicerequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn deviceusestatement_create(
  resource: resources.Deviceusestatement,
  client: FhirClient,
) -> Result(resources.Deviceusestatement, Err) {
  any_create(
    resources.deviceusestatement_to_json(resource),
    resources.RtDeviceusestatement,
    resources.deviceusestatement_decoder(),
    client,
  )
}

pub fn deviceusestatement_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Deviceusestatement, Err) {
  any_read(
    id,
    client,
    resources.RtDeviceusestatement,
    resources.deviceusestatement_decoder(),
  )
}

pub fn deviceusestatement_update(
  resource: resources.Deviceusestatement,
  client: FhirClient,
) -> Result(resources.Deviceusestatement, Err) {
  any_update(
    resource.id,
    resources.deviceusestatement_to_json(resource),
    resources.RtDeviceusestatement,
    resources.deviceusestatement_decoder(),
    client,
  )
}

pub fn deviceusestatement_delete(
  resource: resources.Deviceusestatement,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDeviceusestatement, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn diagnosticreport_create(
  resource: resources.Diagnosticreport,
  client: FhirClient,
) -> Result(resources.Diagnosticreport, Err) {
  any_create(
    resources.diagnosticreport_to_json(resource),
    resources.RtDiagnosticreport,
    resources.diagnosticreport_decoder(),
    client,
  )
}

pub fn diagnosticreport_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Diagnosticreport, Err) {
  any_read(
    id,
    client,
    resources.RtDiagnosticreport,
    resources.diagnosticreport_decoder(),
  )
}

pub fn diagnosticreport_update(
  resource: resources.Diagnosticreport,
  client: FhirClient,
) -> Result(resources.Diagnosticreport, Err) {
  any_update(
    resource.id,
    resources.diagnosticreport_to_json(resource),
    resources.RtDiagnosticreport,
    resources.diagnosticreport_decoder(),
    client,
  )
}

pub fn diagnosticreport_delete(
  resource: resources.Diagnosticreport,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDiagnosticreport, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn documentmanifest_create(
  resource: resources.Documentmanifest,
  client: FhirClient,
) -> Result(resources.Documentmanifest, Err) {
  any_create(
    resources.documentmanifest_to_json(resource),
    resources.RtDocumentmanifest,
    resources.documentmanifest_decoder(),
    client,
  )
}

pub fn documentmanifest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Documentmanifest, Err) {
  any_read(
    id,
    client,
    resources.RtDocumentmanifest,
    resources.documentmanifest_decoder(),
  )
}

pub fn documentmanifest_update(
  resource: resources.Documentmanifest,
  client: FhirClient,
) -> Result(resources.Documentmanifest, Err) {
  any_update(
    resource.id,
    resources.documentmanifest_to_json(resource),
    resources.RtDocumentmanifest,
    resources.documentmanifest_decoder(),
    client,
  )
}

pub fn documentmanifest_delete(
  resource: resources.Documentmanifest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDocumentmanifest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn documentreference_create(
  resource: resources.Documentreference,
  client: FhirClient,
) -> Result(resources.Documentreference, Err) {
  any_create(
    resources.documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.documentreference_decoder(),
    client,
  )
}

pub fn documentreference_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Documentreference, Err) {
  any_read(
    id,
    client,
    resources.RtDocumentreference,
    resources.documentreference_decoder(),
  )
}

pub fn documentreference_update(
  resource: resources.Documentreference,
  client: FhirClient,
) -> Result(resources.Documentreference, Err) {
  any_update(
    resource.id,
    resources.documentreference_to_json(resource),
    resources.RtDocumentreference,
    resources.documentreference_decoder(),
    client,
  )
}

pub fn documentreference_delete(
  resource: resources.Documentreference,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtDocumentreference, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn effectevidencesynthesis_create(
  resource: resources.Effectevidencesynthesis,
  client: FhirClient,
) -> Result(resources.Effectevidencesynthesis, Err) {
  any_create(
    resources.effectevidencesynthesis_to_json(resource),
    resources.RtEffectevidencesynthesis,
    resources.effectevidencesynthesis_decoder(),
    client,
  )
}

pub fn effectevidencesynthesis_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Effectevidencesynthesis, Err) {
  any_read(
    id,
    client,
    resources.RtEffectevidencesynthesis,
    resources.effectevidencesynthesis_decoder(),
  )
}

pub fn effectevidencesynthesis_update(
  resource: resources.Effectevidencesynthesis,
  client: FhirClient,
) -> Result(resources.Effectevidencesynthesis, Err) {
  any_update(
    resource.id,
    resources.effectevidencesynthesis_to_json(resource),
    resources.RtEffectevidencesynthesis,
    resources.effectevidencesynthesis_decoder(),
    client,
  )
}

pub fn effectevidencesynthesis_delete(
  resource: resources.Effectevidencesynthesis,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEffectevidencesynthesis, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn encounter_create(
  resource: resources.Encounter,
  client: FhirClient,
) -> Result(resources.Encounter, Err) {
  any_create(
    resources.encounter_to_json(resource),
    resources.RtEncounter,
    resources.encounter_decoder(),
    client,
  )
}

pub fn encounter_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Encounter, Err) {
  any_read(id, client, resources.RtEncounter, resources.encounter_decoder())
}

pub fn encounter_update(
  resource: resources.Encounter,
  client: FhirClient,
) -> Result(resources.Encounter, Err) {
  any_update(
    resource.id,
    resources.encounter_to_json(resource),
    resources.RtEncounter,
    resources.encounter_decoder(),
    client,
  )
}

pub fn encounter_delete(
  resource: resources.Encounter,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEncounter, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn endpoint_create(
  resource: resources.Endpoint,
  client: FhirClient,
) -> Result(resources.Endpoint, Err) {
  any_create(
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
  )
}

pub fn endpoint_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Endpoint, Err) {
  any_read(id, client, resources.RtEndpoint, resources.endpoint_decoder())
}

pub fn endpoint_update(
  resource: resources.Endpoint,
  client: FhirClient,
) -> Result(resources.Endpoint, Err) {
  any_update(
    resource.id,
    resources.endpoint_to_json(resource),
    resources.RtEndpoint,
    resources.endpoint_decoder(),
    client,
  )
}

pub fn endpoint_delete(
  resource: resources.Endpoint,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEndpoint, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn enrollmentrequest_create(
  resource: resources.Enrollmentrequest,
  client: FhirClient,
) -> Result(resources.Enrollmentrequest, Err) {
  any_create(
    resources.enrollmentrequest_to_json(resource),
    resources.RtEnrollmentrequest,
    resources.enrollmentrequest_decoder(),
    client,
  )
}

pub fn enrollmentrequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Enrollmentrequest, Err) {
  any_read(
    id,
    client,
    resources.RtEnrollmentrequest,
    resources.enrollmentrequest_decoder(),
  )
}

pub fn enrollmentrequest_update(
  resource: resources.Enrollmentrequest,
  client: FhirClient,
) -> Result(resources.Enrollmentrequest, Err) {
  any_update(
    resource.id,
    resources.enrollmentrequest_to_json(resource),
    resources.RtEnrollmentrequest,
    resources.enrollmentrequest_decoder(),
    client,
  )
}

pub fn enrollmentrequest_delete(
  resource: resources.Enrollmentrequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEnrollmentrequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn enrollmentresponse_create(
  resource: resources.Enrollmentresponse,
  client: FhirClient,
) -> Result(resources.Enrollmentresponse, Err) {
  any_create(
    resources.enrollmentresponse_to_json(resource),
    resources.RtEnrollmentresponse,
    resources.enrollmentresponse_decoder(),
    client,
  )
}

pub fn enrollmentresponse_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Enrollmentresponse, Err) {
  any_read(
    id,
    client,
    resources.RtEnrollmentresponse,
    resources.enrollmentresponse_decoder(),
  )
}

pub fn enrollmentresponse_update(
  resource: resources.Enrollmentresponse,
  client: FhirClient,
) -> Result(resources.Enrollmentresponse, Err) {
  any_update(
    resource.id,
    resources.enrollmentresponse_to_json(resource),
    resources.RtEnrollmentresponse,
    resources.enrollmentresponse_decoder(),
    client,
  )
}

pub fn enrollmentresponse_delete(
  resource: resources.Enrollmentresponse,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEnrollmentresponse, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn episodeofcare_create(
  resource: resources.Episodeofcare,
  client: FhirClient,
) -> Result(resources.Episodeofcare, Err) {
  any_create(
    resources.episodeofcare_to_json(resource),
    resources.RtEpisodeofcare,
    resources.episodeofcare_decoder(),
    client,
  )
}

pub fn episodeofcare_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Episodeofcare, Err) {
  any_read(
    id,
    client,
    resources.RtEpisodeofcare,
    resources.episodeofcare_decoder(),
  )
}

pub fn episodeofcare_update(
  resource: resources.Episodeofcare,
  client: FhirClient,
) -> Result(resources.Episodeofcare, Err) {
  any_update(
    resource.id,
    resources.episodeofcare_to_json(resource),
    resources.RtEpisodeofcare,
    resources.episodeofcare_decoder(),
    client,
  )
}

pub fn episodeofcare_delete(
  resource: resources.Episodeofcare,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEpisodeofcare, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn eventdefinition_create(
  resource: resources.Eventdefinition,
  client: FhirClient,
) -> Result(resources.Eventdefinition, Err) {
  any_create(
    resources.eventdefinition_to_json(resource),
    resources.RtEventdefinition,
    resources.eventdefinition_decoder(),
    client,
  )
}

pub fn eventdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Eventdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtEventdefinition,
    resources.eventdefinition_decoder(),
  )
}

pub fn eventdefinition_update(
  resource: resources.Eventdefinition,
  client: FhirClient,
) -> Result(resources.Eventdefinition, Err) {
  any_update(
    resource.id,
    resources.eventdefinition_to_json(resource),
    resources.RtEventdefinition,
    resources.eventdefinition_decoder(),
    client,
  )
}

pub fn eventdefinition_delete(
  resource: resources.Eventdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEventdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn evidence_create(
  resource: resources.Evidence,
  client: FhirClient,
) -> Result(resources.Evidence, Err) {
  any_create(
    resources.evidence_to_json(resource),
    resources.RtEvidence,
    resources.evidence_decoder(),
    client,
  )
}

pub fn evidence_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Evidence, Err) {
  any_read(id, client, resources.RtEvidence, resources.evidence_decoder())
}

pub fn evidence_update(
  resource: resources.Evidence,
  client: FhirClient,
) -> Result(resources.Evidence, Err) {
  any_update(
    resource.id,
    resources.evidence_to_json(resource),
    resources.RtEvidence,
    resources.evidence_decoder(),
    client,
  )
}

pub fn evidence_delete(
  resource: resources.Evidence,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEvidence, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn evidencevariable_create(
  resource: resources.Evidencevariable,
  client: FhirClient,
) -> Result(resources.Evidencevariable, Err) {
  any_create(
    resources.evidencevariable_to_json(resource),
    resources.RtEvidencevariable,
    resources.evidencevariable_decoder(),
    client,
  )
}

pub fn evidencevariable_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Evidencevariable, Err) {
  any_read(
    id,
    client,
    resources.RtEvidencevariable,
    resources.evidencevariable_decoder(),
  )
}

pub fn evidencevariable_update(
  resource: resources.Evidencevariable,
  client: FhirClient,
) -> Result(resources.Evidencevariable, Err) {
  any_update(
    resource.id,
    resources.evidencevariable_to_json(resource),
    resources.RtEvidencevariable,
    resources.evidencevariable_decoder(),
    client,
  )
}

pub fn evidencevariable_delete(
  resource: resources.Evidencevariable,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtEvidencevariable, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn examplescenario_create(
  resource: resources.Examplescenario,
  client: FhirClient,
) -> Result(resources.Examplescenario, Err) {
  any_create(
    resources.examplescenario_to_json(resource),
    resources.RtExamplescenario,
    resources.examplescenario_decoder(),
    client,
  )
}

pub fn examplescenario_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Examplescenario, Err) {
  any_read(
    id,
    client,
    resources.RtExamplescenario,
    resources.examplescenario_decoder(),
  )
}

pub fn examplescenario_update(
  resource: resources.Examplescenario,
  client: FhirClient,
) -> Result(resources.Examplescenario, Err) {
  any_update(
    resource.id,
    resources.examplescenario_to_json(resource),
    resources.RtExamplescenario,
    resources.examplescenario_decoder(),
    client,
  )
}

pub fn examplescenario_delete(
  resource: resources.Examplescenario,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtExamplescenario, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn explanationofbenefit_create(
  resource: resources.Explanationofbenefit,
  client: FhirClient,
) -> Result(resources.Explanationofbenefit, Err) {
  any_create(
    resources.explanationofbenefit_to_json(resource),
    resources.RtExplanationofbenefit,
    resources.explanationofbenefit_decoder(),
    client,
  )
}

pub fn explanationofbenefit_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Explanationofbenefit, Err) {
  any_read(
    id,
    client,
    resources.RtExplanationofbenefit,
    resources.explanationofbenefit_decoder(),
  )
}

pub fn explanationofbenefit_update(
  resource: resources.Explanationofbenefit,
  client: FhirClient,
) -> Result(resources.Explanationofbenefit, Err) {
  any_update(
    resource.id,
    resources.explanationofbenefit_to_json(resource),
    resources.RtExplanationofbenefit,
    resources.explanationofbenefit_decoder(),
    client,
  )
}

pub fn explanationofbenefit_delete(
  resource: resources.Explanationofbenefit,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtExplanationofbenefit, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn familymemberhistory_create(
  resource: resources.Familymemberhistory,
  client: FhirClient,
) -> Result(resources.Familymemberhistory, Err) {
  any_create(
    resources.familymemberhistory_to_json(resource),
    resources.RtFamilymemberhistory,
    resources.familymemberhistory_decoder(),
    client,
  )
}

pub fn familymemberhistory_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Familymemberhistory, Err) {
  any_read(
    id,
    client,
    resources.RtFamilymemberhistory,
    resources.familymemberhistory_decoder(),
  )
}

pub fn familymemberhistory_update(
  resource: resources.Familymemberhistory,
  client: FhirClient,
) -> Result(resources.Familymemberhistory, Err) {
  any_update(
    resource.id,
    resources.familymemberhistory_to_json(resource),
    resources.RtFamilymemberhistory,
    resources.familymemberhistory_decoder(),
    client,
  )
}

pub fn familymemberhistory_delete(
  resource: resources.Familymemberhistory,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtFamilymemberhistory, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn flag_create(
  resource: resources.Flag,
  client: FhirClient,
) -> Result(resources.Flag, Err) {
  any_create(
    resources.flag_to_json(resource),
    resources.RtFlag,
    resources.flag_decoder(),
    client,
  )
}

pub fn flag_read(id: String, client: FhirClient) -> Result(resources.Flag, Err) {
  any_read(id, client, resources.RtFlag, resources.flag_decoder())
}

pub fn flag_update(
  resource: resources.Flag,
  client: FhirClient,
) -> Result(resources.Flag, Err) {
  any_update(
    resource.id,
    resources.flag_to_json(resource),
    resources.RtFlag,
    resources.flag_decoder(),
    client,
  )
}

pub fn flag_delete(
  resource: resources.Flag,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtFlag, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn goal_create(
  resource: resources.Goal,
  client: FhirClient,
) -> Result(resources.Goal, Err) {
  any_create(
    resources.goal_to_json(resource),
    resources.RtGoal,
    resources.goal_decoder(),
    client,
  )
}

pub fn goal_read(id: String, client: FhirClient) -> Result(resources.Goal, Err) {
  any_read(id, client, resources.RtGoal, resources.goal_decoder())
}

pub fn goal_update(
  resource: resources.Goal,
  client: FhirClient,
) -> Result(resources.Goal, Err) {
  any_update(
    resource.id,
    resources.goal_to_json(resource),
    resources.RtGoal,
    resources.goal_decoder(),
    client,
  )
}

pub fn goal_delete(
  resource: resources.Goal,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtGoal, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn graphdefinition_create(
  resource: resources.Graphdefinition,
  client: FhirClient,
) -> Result(resources.Graphdefinition, Err) {
  any_create(
    resources.graphdefinition_to_json(resource),
    resources.RtGraphdefinition,
    resources.graphdefinition_decoder(),
    client,
  )
}

pub fn graphdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Graphdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtGraphdefinition,
    resources.graphdefinition_decoder(),
  )
}

pub fn graphdefinition_update(
  resource: resources.Graphdefinition,
  client: FhirClient,
) -> Result(resources.Graphdefinition, Err) {
  any_update(
    resource.id,
    resources.graphdefinition_to_json(resource),
    resources.RtGraphdefinition,
    resources.graphdefinition_decoder(),
    client,
  )
}

pub fn graphdefinition_delete(
  resource: resources.Graphdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtGraphdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn group_create(
  resource: resources.Group,
  client: FhirClient,
) -> Result(resources.Group, Err) {
  any_create(
    resources.group_to_json(resource),
    resources.RtGroup,
    resources.group_decoder(),
    client,
  )
}

pub fn group_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Group, Err) {
  any_read(id, client, resources.RtGroup, resources.group_decoder())
}

pub fn group_update(
  resource: resources.Group,
  client: FhirClient,
) -> Result(resources.Group, Err) {
  any_update(
    resource.id,
    resources.group_to_json(resource),
    resources.RtGroup,
    resources.group_decoder(),
    client,
  )
}

pub fn group_delete(
  resource: resources.Group,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtGroup, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn guidanceresponse_create(
  resource: resources.Guidanceresponse,
  client: FhirClient,
) -> Result(resources.Guidanceresponse, Err) {
  any_create(
    resources.guidanceresponse_to_json(resource),
    resources.RtGuidanceresponse,
    resources.guidanceresponse_decoder(),
    client,
  )
}

pub fn guidanceresponse_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Guidanceresponse, Err) {
  any_read(
    id,
    client,
    resources.RtGuidanceresponse,
    resources.guidanceresponse_decoder(),
  )
}

pub fn guidanceresponse_update(
  resource: resources.Guidanceresponse,
  client: FhirClient,
) -> Result(resources.Guidanceresponse, Err) {
  any_update(
    resource.id,
    resources.guidanceresponse_to_json(resource),
    resources.RtGuidanceresponse,
    resources.guidanceresponse_decoder(),
    client,
  )
}

pub fn guidanceresponse_delete(
  resource: resources.Guidanceresponse,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtGuidanceresponse, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn healthcareservice_create(
  resource: resources.Healthcareservice,
  client: FhirClient,
) -> Result(resources.Healthcareservice, Err) {
  any_create(
    resources.healthcareservice_to_json(resource),
    resources.RtHealthcareservice,
    resources.healthcareservice_decoder(),
    client,
  )
}

pub fn healthcareservice_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Healthcareservice, Err) {
  any_read(
    id,
    client,
    resources.RtHealthcareservice,
    resources.healthcareservice_decoder(),
  )
}

pub fn healthcareservice_update(
  resource: resources.Healthcareservice,
  client: FhirClient,
) -> Result(resources.Healthcareservice, Err) {
  any_update(
    resource.id,
    resources.healthcareservice_to_json(resource),
    resources.RtHealthcareservice,
    resources.healthcareservice_decoder(),
    client,
  )
}

pub fn healthcareservice_delete(
  resource: resources.Healthcareservice,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtHealthcareservice, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn imagingstudy_create(
  resource: resources.Imagingstudy,
  client: FhirClient,
) -> Result(resources.Imagingstudy, Err) {
  any_create(
    resources.imagingstudy_to_json(resource),
    resources.RtImagingstudy,
    resources.imagingstudy_decoder(),
    client,
  )
}

pub fn imagingstudy_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Imagingstudy, Err) {
  any_read(
    id,
    client,
    resources.RtImagingstudy,
    resources.imagingstudy_decoder(),
  )
}

pub fn imagingstudy_update(
  resource: resources.Imagingstudy,
  client: FhirClient,
) -> Result(resources.Imagingstudy, Err) {
  any_update(
    resource.id,
    resources.imagingstudy_to_json(resource),
    resources.RtImagingstudy,
    resources.imagingstudy_decoder(),
    client,
  )
}

pub fn imagingstudy_delete(
  resource: resources.Imagingstudy,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtImagingstudy, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn immunization_create(
  resource: resources.Immunization,
  client: FhirClient,
) -> Result(resources.Immunization, Err) {
  any_create(
    resources.immunization_to_json(resource),
    resources.RtImmunization,
    resources.immunization_decoder(),
    client,
  )
}

pub fn immunization_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Immunization, Err) {
  any_read(
    id,
    client,
    resources.RtImmunization,
    resources.immunization_decoder(),
  )
}

pub fn immunization_update(
  resource: resources.Immunization,
  client: FhirClient,
) -> Result(resources.Immunization, Err) {
  any_update(
    resource.id,
    resources.immunization_to_json(resource),
    resources.RtImmunization,
    resources.immunization_decoder(),
    client,
  )
}

pub fn immunization_delete(
  resource: resources.Immunization,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtImmunization, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn immunizationevaluation_create(
  resource: resources.Immunizationevaluation,
  client: FhirClient,
) -> Result(resources.Immunizationevaluation, Err) {
  any_create(
    resources.immunizationevaluation_to_json(resource),
    resources.RtImmunizationevaluation,
    resources.immunizationevaluation_decoder(),
    client,
  )
}

pub fn immunizationevaluation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Immunizationevaluation, Err) {
  any_read(
    id,
    client,
    resources.RtImmunizationevaluation,
    resources.immunizationevaluation_decoder(),
  )
}

pub fn immunizationevaluation_update(
  resource: resources.Immunizationevaluation,
  client: FhirClient,
) -> Result(resources.Immunizationevaluation, Err) {
  any_update(
    resource.id,
    resources.immunizationevaluation_to_json(resource),
    resources.RtImmunizationevaluation,
    resources.immunizationevaluation_decoder(),
    client,
  )
}

pub fn immunizationevaluation_delete(
  resource: resources.Immunizationevaluation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtImmunizationevaluation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn immunizationrecommendation_create(
  resource: resources.Immunizationrecommendation,
  client: FhirClient,
) -> Result(resources.Immunizationrecommendation, Err) {
  any_create(
    resources.immunizationrecommendation_to_json(resource),
    resources.RtImmunizationrecommendation,
    resources.immunizationrecommendation_decoder(),
    client,
  )
}

pub fn immunizationrecommendation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Immunizationrecommendation, Err) {
  any_read(
    id,
    client,
    resources.RtImmunizationrecommendation,
    resources.immunizationrecommendation_decoder(),
  )
}

pub fn immunizationrecommendation_update(
  resource: resources.Immunizationrecommendation,
  client: FhirClient,
) -> Result(resources.Immunizationrecommendation, Err) {
  any_update(
    resource.id,
    resources.immunizationrecommendation_to_json(resource),
    resources.RtImmunizationrecommendation,
    resources.immunizationrecommendation_decoder(),
    client,
  )
}

pub fn immunizationrecommendation_delete(
  resource: resources.Immunizationrecommendation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtImmunizationrecommendation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn implementationguide_create(
  resource: resources.Implementationguide,
  client: FhirClient,
) -> Result(resources.Implementationguide, Err) {
  any_create(
    resources.implementationguide_to_json(resource),
    resources.RtImplementationguide,
    resources.implementationguide_decoder(),
    client,
  )
}

pub fn implementationguide_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Implementationguide, Err) {
  any_read(
    id,
    client,
    resources.RtImplementationguide,
    resources.implementationguide_decoder(),
  )
}

pub fn implementationguide_update(
  resource: resources.Implementationguide,
  client: FhirClient,
) -> Result(resources.Implementationguide, Err) {
  any_update(
    resource.id,
    resources.implementationguide_to_json(resource),
    resources.RtImplementationguide,
    resources.implementationguide_decoder(),
    client,
  )
}

pub fn implementationguide_delete(
  resource: resources.Implementationguide,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtImplementationguide, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn insuranceplan_create(
  resource: resources.Insuranceplan,
  client: FhirClient,
) -> Result(resources.Insuranceplan, Err) {
  any_create(
    resources.insuranceplan_to_json(resource),
    resources.RtInsuranceplan,
    resources.insuranceplan_decoder(),
    client,
  )
}

pub fn insuranceplan_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Insuranceplan, Err) {
  any_read(
    id,
    client,
    resources.RtInsuranceplan,
    resources.insuranceplan_decoder(),
  )
}

pub fn insuranceplan_update(
  resource: resources.Insuranceplan,
  client: FhirClient,
) -> Result(resources.Insuranceplan, Err) {
  any_update(
    resource.id,
    resources.insuranceplan_to_json(resource),
    resources.RtInsuranceplan,
    resources.insuranceplan_decoder(),
    client,
  )
}

pub fn insuranceplan_delete(
  resource: resources.Insuranceplan,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtInsuranceplan, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn invoice_create(
  resource: resources.Invoice,
  client: FhirClient,
) -> Result(resources.Invoice, Err) {
  any_create(
    resources.invoice_to_json(resource),
    resources.RtInvoice,
    resources.invoice_decoder(),
    client,
  )
}

pub fn invoice_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Invoice, Err) {
  any_read(id, client, resources.RtInvoice, resources.invoice_decoder())
}

pub fn invoice_update(
  resource: resources.Invoice,
  client: FhirClient,
) -> Result(resources.Invoice, Err) {
  any_update(
    resource.id,
    resources.invoice_to_json(resource),
    resources.RtInvoice,
    resources.invoice_decoder(),
    client,
  )
}

pub fn invoice_delete(
  resource: resources.Invoice,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtInvoice, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn library_create(
  resource: resources.Library,
  client: FhirClient,
) -> Result(resources.Library, Err) {
  any_create(
    resources.library_to_json(resource),
    resources.RtLibrary,
    resources.library_decoder(),
    client,
  )
}

pub fn library_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Library, Err) {
  any_read(id, client, resources.RtLibrary, resources.library_decoder())
}

pub fn library_update(
  resource: resources.Library,
  client: FhirClient,
) -> Result(resources.Library, Err) {
  any_update(
    resource.id,
    resources.library_to_json(resource),
    resources.RtLibrary,
    resources.library_decoder(),
    client,
  )
}

pub fn library_delete(
  resource: resources.Library,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtLibrary, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn linkage_create(
  resource: resources.Linkage,
  client: FhirClient,
) -> Result(resources.Linkage, Err) {
  any_create(
    resources.linkage_to_json(resource),
    resources.RtLinkage,
    resources.linkage_decoder(),
    client,
  )
}

pub fn linkage_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Linkage, Err) {
  any_read(id, client, resources.RtLinkage, resources.linkage_decoder())
}

pub fn linkage_update(
  resource: resources.Linkage,
  client: FhirClient,
) -> Result(resources.Linkage, Err) {
  any_update(
    resource.id,
    resources.linkage_to_json(resource),
    resources.RtLinkage,
    resources.linkage_decoder(),
    client,
  )
}

pub fn linkage_delete(
  resource: resources.Linkage,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtLinkage, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn listfhir_create(
  resource: resources.Listfhir,
  client: FhirClient,
) -> Result(resources.Listfhir, Err) {
  any_create(
    resources.listfhir_to_json(resource),
    resources.RtListfhir,
    resources.listfhir_decoder(),
    client,
  )
}

pub fn listfhir_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Listfhir, Err) {
  any_read(id, client, resources.RtListfhir, resources.listfhir_decoder())
}

pub fn listfhir_update(
  resource: resources.Listfhir,
  client: FhirClient,
) -> Result(resources.Listfhir, Err) {
  any_update(
    resource.id,
    resources.listfhir_to_json(resource),
    resources.RtListfhir,
    resources.listfhir_decoder(),
    client,
  )
}

pub fn listfhir_delete(
  resource: resources.Listfhir,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtListfhir, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn location_create(
  resource: resources.Location,
  client: FhirClient,
) -> Result(resources.Location, Err) {
  any_create(
    resources.location_to_json(resource),
    resources.RtLocation,
    resources.location_decoder(),
    client,
  )
}

pub fn location_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Location, Err) {
  any_read(id, client, resources.RtLocation, resources.location_decoder())
}

pub fn location_update(
  resource: resources.Location,
  client: FhirClient,
) -> Result(resources.Location, Err) {
  any_update(
    resource.id,
    resources.location_to_json(resource),
    resources.RtLocation,
    resources.location_decoder(),
    client,
  )
}

pub fn location_delete(
  resource: resources.Location,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtLocation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn measure_create(
  resource: resources.Measure,
  client: FhirClient,
) -> Result(resources.Measure, Err) {
  any_create(
    resources.measure_to_json(resource),
    resources.RtMeasure,
    resources.measure_decoder(),
    client,
  )
}

pub fn measure_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Measure, Err) {
  any_read(id, client, resources.RtMeasure, resources.measure_decoder())
}

pub fn measure_update(
  resource: resources.Measure,
  client: FhirClient,
) -> Result(resources.Measure, Err) {
  any_update(
    resource.id,
    resources.measure_to_json(resource),
    resources.RtMeasure,
    resources.measure_decoder(),
    client,
  )
}

pub fn measure_delete(
  resource: resources.Measure,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMeasure, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn measurereport_create(
  resource: resources.Measurereport,
  client: FhirClient,
) -> Result(resources.Measurereport, Err) {
  any_create(
    resources.measurereport_to_json(resource),
    resources.RtMeasurereport,
    resources.measurereport_decoder(),
    client,
  )
}

pub fn measurereport_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Measurereport, Err) {
  any_read(
    id,
    client,
    resources.RtMeasurereport,
    resources.measurereport_decoder(),
  )
}

pub fn measurereport_update(
  resource: resources.Measurereport,
  client: FhirClient,
) -> Result(resources.Measurereport, Err) {
  any_update(
    resource.id,
    resources.measurereport_to_json(resource),
    resources.RtMeasurereport,
    resources.measurereport_decoder(),
    client,
  )
}

pub fn measurereport_delete(
  resource: resources.Measurereport,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMeasurereport, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn media_create(
  resource: resources.Media,
  client: FhirClient,
) -> Result(resources.Media, Err) {
  any_create(
    resources.media_to_json(resource),
    resources.RtMedia,
    resources.media_decoder(),
    client,
  )
}

pub fn media_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Media, Err) {
  any_read(id, client, resources.RtMedia, resources.media_decoder())
}

pub fn media_update(
  resource: resources.Media,
  client: FhirClient,
) -> Result(resources.Media, Err) {
  any_update(
    resource.id,
    resources.media_to_json(resource),
    resources.RtMedia,
    resources.media_decoder(),
    client,
  )
}

pub fn media_delete(
  resource: resources.Media,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedia, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medication_create(
  resource: resources.Medication,
  client: FhirClient,
) -> Result(resources.Medication, Err) {
  any_create(
    resources.medication_to_json(resource),
    resources.RtMedication,
    resources.medication_decoder(),
    client,
  )
}

pub fn medication_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medication, Err) {
  any_read(id, client, resources.RtMedication, resources.medication_decoder())
}

pub fn medication_update(
  resource: resources.Medication,
  client: FhirClient,
) -> Result(resources.Medication, Err) {
  any_update(
    resource.id,
    resources.medication_to_json(resource),
    resources.RtMedication,
    resources.medication_decoder(),
    client,
  )
}

pub fn medication_delete(
  resource: resources.Medication,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedication, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicationadministration_create(
  resource: resources.Medicationadministration,
  client: FhirClient,
) -> Result(resources.Medicationadministration, Err) {
  any_create(
    resources.medicationadministration_to_json(resource),
    resources.RtMedicationadministration,
    resources.medicationadministration_decoder(),
    client,
  )
}

pub fn medicationadministration_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicationadministration, Err) {
  any_read(
    id,
    client,
    resources.RtMedicationadministration,
    resources.medicationadministration_decoder(),
  )
}

pub fn medicationadministration_update(
  resource: resources.Medicationadministration,
  client: FhirClient,
) -> Result(resources.Medicationadministration, Err) {
  any_update(
    resource.id,
    resources.medicationadministration_to_json(resource),
    resources.RtMedicationadministration,
    resources.medicationadministration_decoder(),
    client,
  )
}

pub fn medicationadministration_delete(
  resource: resources.Medicationadministration,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicationadministration, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicationdispense_create(
  resource: resources.Medicationdispense,
  client: FhirClient,
) -> Result(resources.Medicationdispense, Err) {
  any_create(
    resources.medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.medicationdispense_decoder(),
    client,
  )
}

pub fn medicationdispense_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicationdispense, Err) {
  any_read(
    id,
    client,
    resources.RtMedicationdispense,
    resources.medicationdispense_decoder(),
  )
}

pub fn medicationdispense_update(
  resource: resources.Medicationdispense,
  client: FhirClient,
) -> Result(resources.Medicationdispense, Err) {
  any_update(
    resource.id,
    resources.medicationdispense_to_json(resource),
    resources.RtMedicationdispense,
    resources.medicationdispense_decoder(),
    client,
  )
}

pub fn medicationdispense_delete(
  resource: resources.Medicationdispense,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicationdispense, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicationknowledge_create(
  resource: resources.Medicationknowledge,
  client: FhirClient,
) -> Result(resources.Medicationknowledge, Err) {
  any_create(
    resources.medicationknowledge_to_json(resource),
    resources.RtMedicationknowledge,
    resources.medicationknowledge_decoder(),
    client,
  )
}

pub fn medicationknowledge_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicationknowledge, Err) {
  any_read(
    id,
    client,
    resources.RtMedicationknowledge,
    resources.medicationknowledge_decoder(),
  )
}

pub fn medicationknowledge_update(
  resource: resources.Medicationknowledge,
  client: FhirClient,
) -> Result(resources.Medicationknowledge, Err) {
  any_update(
    resource.id,
    resources.medicationknowledge_to_json(resource),
    resources.RtMedicationknowledge,
    resources.medicationknowledge_decoder(),
    client,
  )
}

pub fn medicationknowledge_delete(
  resource: resources.Medicationknowledge,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicationknowledge, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicationrequest_create(
  resource: resources.Medicationrequest,
  client: FhirClient,
) -> Result(resources.Medicationrequest, Err) {
  any_create(
    resources.medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.medicationrequest_decoder(),
    client,
  )
}

pub fn medicationrequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicationrequest, Err) {
  any_read(
    id,
    client,
    resources.RtMedicationrequest,
    resources.medicationrequest_decoder(),
  )
}

pub fn medicationrequest_update(
  resource: resources.Medicationrequest,
  client: FhirClient,
) -> Result(resources.Medicationrequest, Err) {
  any_update(
    resource.id,
    resources.medicationrequest_to_json(resource),
    resources.RtMedicationrequest,
    resources.medicationrequest_decoder(),
    client,
  )
}

pub fn medicationrequest_delete(
  resource: resources.Medicationrequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicationrequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicationstatement_create(
  resource: resources.Medicationstatement,
  client: FhirClient,
) -> Result(resources.Medicationstatement, Err) {
  any_create(
    resources.medicationstatement_to_json(resource),
    resources.RtMedicationstatement,
    resources.medicationstatement_decoder(),
    client,
  )
}

pub fn medicationstatement_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicationstatement, Err) {
  any_read(
    id,
    client,
    resources.RtMedicationstatement,
    resources.medicationstatement_decoder(),
  )
}

pub fn medicationstatement_update(
  resource: resources.Medicationstatement,
  client: FhirClient,
) -> Result(resources.Medicationstatement, Err) {
  any_update(
    resource.id,
    resources.medicationstatement_to_json(resource),
    resources.RtMedicationstatement,
    resources.medicationstatement_decoder(),
    client,
  )
}

pub fn medicationstatement_delete(
  resource: resources.Medicationstatement,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicationstatement, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproduct_create(
  resource: resources.Medicinalproduct,
  client: FhirClient,
) -> Result(resources.Medicinalproduct, Err) {
  any_create(
    resources.medicinalproduct_to_json(resource),
    resources.RtMedicinalproduct,
    resources.medicinalproduct_decoder(),
    client,
  )
}

pub fn medicinalproduct_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproduct, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproduct,
    resources.medicinalproduct_decoder(),
  )
}

pub fn medicinalproduct_update(
  resource: resources.Medicinalproduct,
  client: FhirClient,
) -> Result(resources.Medicinalproduct, Err) {
  any_update(
    resource.id,
    resources.medicinalproduct_to_json(resource),
    resources.RtMedicinalproduct,
    resources.medicinalproduct_decoder(),
    client,
  )
}

pub fn medicinalproduct_delete(
  resource: resources.Medicinalproduct,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicinalproduct, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductauthorization_create(
  resource: resources.Medicinalproductauthorization,
  client: FhirClient,
) -> Result(resources.Medicinalproductauthorization, Err) {
  any_create(
    resources.medicinalproductauthorization_to_json(resource),
    resources.RtMedicinalproductauthorization,
    resources.medicinalproductauthorization_decoder(),
    client,
  )
}

pub fn medicinalproductauthorization_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductauthorization, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductauthorization,
    resources.medicinalproductauthorization_decoder(),
  )
}

pub fn medicinalproductauthorization_update(
  resource: resources.Medicinalproductauthorization,
  client: FhirClient,
) -> Result(resources.Medicinalproductauthorization, Err) {
  any_update(
    resource.id,
    resources.medicinalproductauthorization_to_json(resource),
    resources.RtMedicinalproductauthorization,
    resources.medicinalproductauthorization_decoder(),
    client,
  )
}

pub fn medicinalproductauthorization_delete(
  resource: resources.Medicinalproductauthorization,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) ->
      any_delete(id, resources.RtMedicinalproductauthorization, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductcontraindication_create(
  resource: resources.Medicinalproductcontraindication,
  client: FhirClient,
) -> Result(resources.Medicinalproductcontraindication, Err) {
  any_create(
    resources.medicinalproductcontraindication_to_json(resource),
    resources.RtMedicinalproductcontraindication,
    resources.medicinalproductcontraindication_decoder(),
    client,
  )
}

pub fn medicinalproductcontraindication_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductcontraindication, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductcontraindication,
    resources.medicinalproductcontraindication_decoder(),
  )
}

pub fn medicinalproductcontraindication_update(
  resource: resources.Medicinalproductcontraindication,
  client: FhirClient,
) -> Result(resources.Medicinalproductcontraindication, Err) {
  any_update(
    resource.id,
    resources.medicinalproductcontraindication_to_json(resource),
    resources.RtMedicinalproductcontraindication,
    resources.medicinalproductcontraindication_decoder(),
    client,
  )
}

pub fn medicinalproductcontraindication_delete(
  resource: resources.Medicinalproductcontraindication,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) ->
      any_delete(id, resources.RtMedicinalproductcontraindication, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductindication_create(
  resource: resources.Medicinalproductindication,
  client: FhirClient,
) -> Result(resources.Medicinalproductindication, Err) {
  any_create(
    resources.medicinalproductindication_to_json(resource),
    resources.RtMedicinalproductindication,
    resources.medicinalproductindication_decoder(),
    client,
  )
}

pub fn medicinalproductindication_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductindication, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductindication,
    resources.medicinalproductindication_decoder(),
  )
}

pub fn medicinalproductindication_update(
  resource: resources.Medicinalproductindication,
  client: FhirClient,
) -> Result(resources.Medicinalproductindication, Err) {
  any_update(
    resource.id,
    resources.medicinalproductindication_to_json(resource),
    resources.RtMedicinalproductindication,
    resources.medicinalproductindication_decoder(),
    client,
  )
}

pub fn medicinalproductindication_delete(
  resource: resources.Medicinalproductindication,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicinalproductindication, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductingredient_create(
  resource: resources.Medicinalproductingredient,
  client: FhirClient,
) -> Result(resources.Medicinalproductingredient, Err) {
  any_create(
    resources.medicinalproductingredient_to_json(resource),
    resources.RtMedicinalproductingredient,
    resources.medicinalproductingredient_decoder(),
    client,
  )
}

pub fn medicinalproductingredient_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductingredient, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductingredient,
    resources.medicinalproductingredient_decoder(),
  )
}

pub fn medicinalproductingredient_update(
  resource: resources.Medicinalproductingredient,
  client: FhirClient,
) -> Result(resources.Medicinalproductingredient, Err) {
  any_update(
    resource.id,
    resources.medicinalproductingredient_to_json(resource),
    resources.RtMedicinalproductingredient,
    resources.medicinalproductingredient_decoder(),
    client,
  )
}

pub fn medicinalproductingredient_delete(
  resource: resources.Medicinalproductingredient,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicinalproductingredient, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductinteraction_create(
  resource: resources.Medicinalproductinteraction,
  client: FhirClient,
) -> Result(resources.Medicinalproductinteraction, Err) {
  any_create(
    resources.medicinalproductinteraction_to_json(resource),
    resources.RtMedicinalproductinteraction,
    resources.medicinalproductinteraction_decoder(),
    client,
  )
}

pub fn medicinalproductinteraction_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductinteraction, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductinteraction,
    resources.medicinalproductinteraction_decoder(),
  )
}

pub fn medicinalproductinteraction_update(
  resource: resources.Medicinalproductinteraction,
  client: FhirClient,
) -> Result(resources.Medicinalproductinteraction, Err) {
  any_update(
    resource.id,
    resources.medicinalproductinteraction_to_json(resource),
    resources.RtMedicinalproductinteraction,
    resources.medicinalproductinteraction_decoder(),
    client,
  )
}

pub fn medicinalproductinteraction_delete(
  resource: resources.Medicinalproductinteraction,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicinalproductinteraction, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductmanufactured_create(
  resource: resources.Medicinalproductmanufactured,
  client: FhirClient,
) -> Result(resources.Medicinalproductmanufactured, Err) {
  any_create(
    resources.medicinalproductmanufactured_to_json(resource),
    resources.RtMedicinalproductmanufactured,
    resources.medicinalproductmanufactured_decoder(),
    client,
  )
}

pub fn medicinalproductmanufactured_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductmanufactured, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductmanufactured,
    resources.medicinalproductmanufactured_decoder(),
  )
}

pub fn medicinalproductmanufactured_update(
  resource: resources.Medicinalproductmanufactured,
  client: FhirClient,
) -> Result(resources.Medicinalproductmanufactured, Err) {
  any_update(
    resource.id,
    resources.medicinalproductmanufactured_to_json(resource),
    resources.RtMedicinalproductmanufactured,
    resources.medicinalproductmanufactured_decoder(),
    client,
  )
}

pub fn medicinalproductmanufactured_delete(
  resource: resources.Medicinalproductmanufactured,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicinalproductmanufactured, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductpackaged_create(
  resource: resources.Medicinalproductpackaged,
  client: FhirClient,
) -> Result(resources.Medicinalproductpackaged, Err) {
  any_create(
    resources.medicinalproductpackaged_to_json(resource),
    resources.RtMedicinalproductpackaged,
    resources.medicinalproductpackaged_decoder(),
    client,
  )
}

pub fn medicinalproductpackaged_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductpackaged, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductpackaged,
    resources.medicinalproductpackaged_decoder(),
  )
}

pub fn medicinalproductpackaged_update(
  resource: resources.Medicinalproductpackaged,
  client: FhirClient,
) -> Result(resources.Medicinalproductpackaged, Err) {
  any_update(
    resource.id,
    resources.medicinalproductpackaged_to_json(resource),
    resources.RtMedicinalproductpackaged,
    resources.medicinalproductpackaged_decoder(),
    client,
  )
}

pub fn medicinalproductpackaged_delete(
  resource: resources.Medicinalproductpackaged,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMedicinalproductpackaged, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductpharmaceutical_create(
  resource: resources.Medicinalproductpharmaceutical,
  client: FhirClient,
) -> Result(resources.Medicinalproductpharmaceutical, Err) {
  any_create(
    resources.medicinalproductpharmaceutical_to_json(resource),
    resources.RtMedicinalproductpharmaceutical,
    resources.medicinalproductpharmaceutical_decoder(),
    client,
  )
}

pub fn medicinalproductpharmaceutical_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductpharmaceutical, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductpharmaceutical,
    resources.medicinalproductpharmaceutical_decoder(),
  )
}

pub fn medicinalproductpharmaceutical_update(
  resource: resources.Medicinalproductpharmaceutical,
  client: FhirClient,
) -> Result(resources.Medicinalproductpharmaceutical, Err) {
  any_update(
    resource.id,
    resources.medicinalproductpharmaceutical_to_json(resource),
    resources.RtMedicinalproductpharmaceutical,
    resources.medicinalproductpharmaceutical_decoder(),
    client,
  )
}

pub fn medicinalproductpharmaceutical_delete(
  resource: resources.Medicinalproductpharmaceutical,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) ->
      any_delete(id, resources.RtMedicinalproductpharmaceutical, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn medicinalproductundesirableeffect_create(
  resource: resources.Medicinalproductundesirableeffect,
  client: FhirClient,
) -> Result(resources.Medicinalproductundesirableeffect, Err) {
  any_create(
    resources.medicinalproductundesirableeffect_to_json(resource),
    resources.RtMedicinalproductundesirableeffect,
    resources.medicinalproductundesirableeffect_decoder(),
    client,
  )
}

pub fn medicinalproductundesirableeffect_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Medicinalproductundesirableeffect, Err) {
  any_read(
    id,
    client,
    resources.RtMedicinalproductundesirableeffect,
    resources.medicinalproductundesirableeffect_decoder(),
  )
}

pub fn medicinalproductundesirableeffect_update(
  resource: resources.Medicinalproductundesirableeffect,
  client: FhirClient,
) -> Result(resources.Medicinalproductundesirableeffect, Err) {
  any_update(
    resource.id,
    resources.medicinalproductundesirableeffect_to_json(resource),
    resources.RtMedicinalproductundesirableeffect,
    resources.medicinalproductundesirableeffect_decoder(),
    client,
  )
}

pub fn medicinalproductundesirableeffect_delete(
  resource: resources.Medicinalproductundesirableeffect,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) ->
      any_delete(id, resources.RtMedicinalproductundesirableeffect, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn messagedefinition_create(
  resource: resources.Messagedefinition,
  client: FhirClient,
) -> Result(resources.Messagedefinition, Err) {
  any_create(
    resources.messagedefinition_to_json(resource),
    resources.RtMessagedefinition,
    resources.messagedefinition_decoder(),
    client,
  )
}

pub fn messagedefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Messagedefinition, Err) {
  any_read(
    id,
    client,
    resources.RtMessagedefinition,
    resources.messagedefinition_decoder(),
  )
}

pub fn messagedefinition_update(
  resource: resources.Messagedefinition,
  client: FhirClient,
) -> Result(resources.Messagedefinition, Err) {
  any_update(
    resource.id,
    resources.messagedefinition_to_json(resource),
    resources.RtMessagedefinition,
    resources.messagedefinition_decoder(),
    client,
  )
}

pub fn messagedefinition_delete(
  resource: resources.Messagedefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMessagedefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn messageheader_create(
  resource: resources.Messageheader,
  client: FhirClient,
) -> Result(resources.Messageheader, Err) {
  any_create(
    resources.messageheader_to_json(resource),
    resources.RtMessageheader,
    resources.messageheader_decoder(),
    client,
  )
}

pub fn messageheader_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Messageheader, Err) {
  any_read(
    id,
    client,
    resources.RtMessageheader,
    resources.messageheader_decoder(),
  )
}

pub fn messageheader_update(
  resource: resources.Messageheader,
  client: FhirClient,
) -> Result(resources.Messageheader, Err) {
  any_update(
    resource.id,
    resources.messageheader_to_json(resource),
    resources.RtMessageheader,
    resources.messageheader_decoder(),
    client,
  )
}

pub fn messageheader_delete(
  resource: resources.Messageheader,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMessageheader, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn molecularsequence_create(
  resource: resources.Molecularsequence,
  client: FhirClient,
) -> Result(resources.Molecularsequence, Err) {
  any_create(
    resources.molecularsequence_to_json(resource),
    resources.RtMolecularsequence,
    resources.molecularsequence_decoder(),
    client,
  )
}

pub fn molecularsequence_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Molecularsequence, Err) {
  any_read(
    id,
    client,
    resources.RtMolecularsequence,
    resources.molecularsequence_decoder(),
  )
}

pub fn molecularsequence_update(
  resource: resources.Molecularsequence,
  client: FhirClient,
) -> Result(resources.Molecularsequence, Err) {
  any_update(
    resource.id,
    resources.molecularsequence_to_json(resource),
    resources.RtMolecularsequence,
    resources.molecularsequence_decoder(),
    client,
  )
}

pub fn molecularsequence_delete(
  resource: resources.Molecularsequence,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtMolecularsequence, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn namingsystem_create(
  resource: resources.Namingsystem,
  client: FhirClient,
) -> Result(resources.Namingsystem, Err) {
  any_create(
    resources.namingsystem_to_json(resource),
    resources.RtNamingsystem,
    resources.namingsystem_decoder(),
    client,
  )
}

pub fn namingsystem_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Namingsystem, Err) {
  any_read(
    id,
    client,
    resources.RtNamingsystem,
    resources.namingsystem_decoder(),
  )
}

pub fn namingsystem_update(
  resource: resources.Namingsystem,
  client: FhirClient,
) -> Result(resources.Namingsystem, Err) {
  any_update(
    resource.id,
    resources.namingsystem_to_json(resource),
    resources.RtNamingsystem,
    resources.namingsystem_decoder(),
    client,
  )
}

pub fn namingsystem_delete(
  resource: resources.Namingsystem,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtNamingsystem, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn nutritionorder_create(
  resource: resources.Nutritionorder,
  client: FhirClient,
) -> Result(resources.Nutritionorder, Err) {
  any_create(
    resources.nutritionorder_to_json(resource),
    resources.RtNutritionorder,
    resources.nutritionorder_decoder(),
    client,
  )
}

pub fn nutritionorder_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Nutritionorder, Err) {
  any_read(
    id,
    client,
    resources.RtNutritionorder,
    resources.nutritionorder_decoder(),
  )
}

pub fn nutritionorder_update(
  resource: resources.Nutritionorder,
  client: FhirClient,
) -> Result(resources.Nutritionorder, Err) {
  any_update(
    resource.id,
    resources.nutritionorder_to_json(resource),
    resources.RtNutritionorder,
    resources.nutritionorder_decoder(),
    client,
  )
}

pub fn nutritionorder_delete(
  resource: resources.Nutritionorder,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtNutritionorder, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn observation_create(
  resource: resources.Observation,
  client: FhirClient,
) -> Result(resources.Observation, Err) {
  any_create(
    resources.observation_to_json(resource),
    resources.RtObservation,
    resources.observation_decoder(),
    client,
  )
}

pub fn observation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Observation, Err) {
  any_read(id, client, resources.RtObservation, resources.observation_decoder())
}

pub fn observation_update(
  resource: resources.Observation,
  client: FhirClient,
) -> Result(resources.Observation, Err) {
  any_update(
    resource.id,
    resources.observation_to_json(resource),
    resources.RtObservation,
    resources.observation_decoder(),
    client,
  )
}

pub fn observation_delete(
  resource: resources.Observation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn observationdefinition_create(
  resource: resources.Observationdefinition,
  client: FhirClient,
) -> Result(resources.Observationdefinition, Err) {
  any_create(
    resources.observationdefinition_to_json(resource),
    resources.RtObservationdefinition,
    resources.observationdefinition_decoder(),
    client,
  )
}

pub fn observationdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Observationdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtObservationdefinition,
    resources.observationdefinition_decoder(),
  )
}

pub fn observationdefinition_update(
  resource: resources.Observationdefinition,
  client: FhirClient,
) -> Result(resources.Observationdefinition, Err) {
  any_update(
    resource.id,
    resources.observationdefinition_to_json(resource),
    resources.RtObservationdefinition,
    resources.observationdefinition_decoder(),
    client,
  )
}

pub fn observationdefinition_delete(
  resource: resources.Observationdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtObservationdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn operationdefinition_create(
  resource: resources.Operationdefinition,
  client: FhirClient,
) -> Result(resources.Operationdefinition, Err) {
  any_create(
    resources.operationdefinition_to_json(resource),
    resources.RtOperationdefinition,
    resources.operationdefinition_decoder(),
    client,
  )
}

pub fn operationdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Operationdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtOperationdefinition,
    resources.operationdefinition_decoder(),
  )
}

pub fn operationdefinition_update(
  resource: resources.Operationdefinition,
  client: FhirClient,
) -> Result(resources.Operationdefinition, Err) {
  any_update(
    resource.id,
    resources.operationdefinition_to_json(resource),
    resources.RtOperationdefinition,
    resources.operationdefinition_decoder(),
    client,
  )
}

pub fn operationdefinition_delete(
  resource: resources.Operationdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtOperationdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn operationoutcome_create(
  resource: resources.Operationoutcome,
  client: FhirClient,
) -> Result(resources.Operationoutcome, Err) {
  any_create(
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
  )
}

pub fn operationoutcome_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Operationoutcome, Err) {
  any_read(
    id,
    client,
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
  )
}

pub fn operationoutcome_update(
  resource: resources.Operationoutcome,
  client: FhirClient,
) -> Result(resources.Operationoutcome, Err) {
  any_update(
    resource.id,
    resources.operationoutcome_to_json(resource),
    resources.RtOperationoutcome,
    resources.operationoutcome_decoder(),
    client,
  )
}

pub fn operationoutcome_delete(
  resource: resources.Operationoutcome,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtOperationoutcome, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn organization_create(
  resource: resources.Organization,
  client: FhirClient,
) -> Result(resources.Organization, Err) {
  any_create(
    resources.organization_to_json(resource),
    resources.RtOrganization,
    resources.organization_decoder(),
    client,
  )
}

pub fn organization_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Organization, Err) {
  any_read(
    id,
    client,
    resources.RtOrganization,
    resources.organization_decoder(),
  )
}

pub fn organization_update(
  resource: resources.Organization,
  client: FhirClient,
) -> Result(resources.Organization, Err) {
  any_update(
    resource.id,
    resources.organization_to_json(resource),
    resources.RtOrganization,
    resources.organization_decoder(),
    client,
  )
}

pub fn organization_delete(
  resource: resources.Organization,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtOrganization, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn organizationaffiliation_create(
  resource: resources.Organizationaffiliation,
  client: FhirClient,
) -> Result(resources.Organizationaffiliation, Err) {
  any_create(
    resources.organizationaffiliation_to_json(resource),
    resources.RtOrganizationaffiliation,
    resources.organizationaffiliation_decoder(),
    client,
  )
}

pub fn organizationaffiliation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Organizationaffiliation, Err) {
  any_read(
    id,
    client,
    resources.RtOrganizationaffiliation,
    resources.organizationaffiliation_decoder(),
  )
}

pub fn organizationaffiliation_update(
  resource: resources.Organizationaffiliation,
  client: FhirClient,
) -> Result(resources.Organizationaffiliation, Err) {
  any_update(
    resource.id,
    resources.organizationaffiliation_to_json(resource),
    resources.RtOrganizationaffiliation,
    resources.organizationaffiliation_decoder(),
    client,
  )
}

pub fn organizationaffiliation_delete(
  resource: resources.Organizationaffiliation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtOrganizationaffiliation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn patient_create(
  resource: resources.Patient,
  client: FhirClient,
) -> Result(resources.Patient, Err) {
  any_create(
    resources.patient_to_json(resource),
    resources.RtPatient,
    resources.patient_decoder(),
    client,
  )
}

pub fn patient_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Patient, Err) {
  any_read(id, client, resources.RtPatient, resources.patient_decoder())
}

pub fn patient_update(
  resource: resources.Patient,
  client: FhirClient,
) -> Result(resources.Patient, Err) {
  any_update(
    resource.id,
    resources.patient_to_json(resource),
    resources.RtPatient,
    resources.patient_decoder(),
    client,
  )
}

pub fn patient_delete(
  resource: resources.Patient,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPatient, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn paymentnotice_create(
  resource: resources.Paymentnotice,
  client: FhirClient,
) -> Result(resources.Paymentnotice, Err) {
  any_create(
    resources.paymentnotice_to_json(resource),
    resources.RtPaymentnotice,
    resources.paymentnotice_decoder(),
    client,
  )
}

pub fn paymentnotice_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Paymentnotice, Err) {
  any_read(
    id,
    client,
    resources.RtPaymentnotice,
    resources.paymentnotice_decoder(),
  )
}

pub fn paymentnotice_update(
  resource: resources.Paymentnotice,
  client: FhirClient,
) -> Result(resources.Paymentnotice, Err) {
  any_update(
    resource.id,
    resources.paymentnotice_to_json(resource),
    resources.RtPaymentnotice,
    resources.paymentnotice_decoder(),
    client,
  )
}

pub fn paymentnotice_delete(
  resource: resources.Paymentnotice,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPaymentnotice, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn paymentreconciliation_create(
  resource: resources.Paymentreconciliation,
  client: FhirClient,
) -> Result(resources.Paymentreconciliation, Err) {
  any_create(
    resources.paymentreconciliation_to_json(resource),
    resources.RtPaymentreconciliation,
    resources.paymentreconciliation_decoder(),
    client,
  )
}

pub fn paymentreconciliation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Paymentreconciliation, Err) {
  any_read(
    id,
    client,
    resources.RtPaymentreconciliation,
    resources.paymentreconciliation_decoder(),
  )
}

pub fn paymentreconciliation_update(
  resource: resources.Paymentreconciliation,
  client: FhirClient,
) -> Result(resources.Paymentreconciliation, Err) {
  any_update(
    resource.id,
    resources.paymentreconciliation_to_json(resource),
    resources.RtPaymentreconciliation,
    resources.paymentreconciliation_decoder(),
    client,
  )
}

pub fn paymentreconciliation_delete(
  resource: resources.Paymentreconciliation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPaymentreconciliation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn person_create(
  resource: resources.Person,
  client: FhirClient,
) -> Result(resources.Person, Err) {
  any_create(
    resources.person_to_json(resource),
    resources.RtPerson,
    resources.person_decoder(),
    client,
  )
}

pub fn person_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Person, Err) {
  any_read(id, client, resources.RtPerson, resources.person_decoder())
}

pub fn person_update(
  resource: resources.Person,
  client: FhirClient,
) -> Result(resources.Person, Err) {
  any_update(
    resource.id,
    resources.person_to_json(resource),
    resources.RtPerson,
    resources.person_decoder(),
    client,
  )
}

pub fn person_delete(
  resource: resources.Person,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPerson, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn plandefinition_create(
  resource: resources.Plandefinition,
  client: FhirClient,
) -> Result(resources.Plandefinition, Err) {
  any_create(
    resources.plandefinition_to_json(resource),
    resources.RtPlandefinition,
    resources.plandefinition_decoder(),
    client,
  )
}

pub fn plandefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Plandefinition, Err) {
  any_read(
    id,
    client,
    resources.RtPlandefinition,
    resources.plandefinition_decoder(),
  )
}

pub fn plandefinition_update(
  resource: resources.Plandefinition,
  client: FhirClient,
) -> Result(resources.Plandefinition, Err) {
  any_update(
    resource.id,
    resources.plandefinition_to_json(resource),
    resources.RtPlandefinition,
    resources.plandefinition_decoder(),
    client,
  )
}

pub fn plandefinition_delete(
  resource: resources.Plandefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPlandefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn practitioner_create(
  resource: resources.Practitioner,
  client: FhirClient,
) -> Result(resources.Practitioner, Err) {
  any_create(
    resources.practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.practitioner_decoder(),
    client,
  )
}

pub fn practitioner_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Practitioner, Err) {
  any_read(
    id,
    client,
    resources.RtPractitioner,
    resources.practitioner_decoder(),
  )
}

pub fn practitioner_update(
  resource: resources.Practitioner,
  client: FhirClient,
) -> Result(resources.Practitioner, Err) {
  any_update(
    resource.id,
    resources.practitioner_to_json(resource),
    resources.RtPractitioner,
    resources.practitioner_decoder(),
    client,
  )
}

pub fn practitioner_delete(
  resource: resources.Practitioner,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPractitioner, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn practitionerrole_create(
  resource: resources.Practitionerrole,
  client: FhirClient,
) -> Result(resources.Practitionerrole, Err) {
  any_create(
    resources.practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.practitionerrole_decoder(),
    client,
  )
}

pub fn practitionerrole_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Practitionerrole, Err) {
  any_read(
    id,
    client,
    resources.RtPractitionerrole,
    resources.practitionerrole_decoder(),
  )
}

pub fn practitionerrole_update(
  resource: resources.Practitionerrole,
  client: FhirClient,
) -> Result(resources.Practitionerrole, Err) {
  any_update(
    resource.id,
    resources.practitionerrole_to_json(resource),
    resources.RtPractitionerrole,
    resources.practitionerrole_decoder(),
    client,
  )
}

pub fn practitionerrole_delete(
  resource: resources.Practitionerrole,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtPractitionerrole, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn procedure_create(
  resource: resources.Procedure,
  client: FhirClient,
) -> Result(resources.Procedure, Err) {
  any_create(
    resources.procedure_to_json(resource),
    resources.RtProcedure,
    resources.procedure_decoder(),
    client,
  )
}

pub fn procedure_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Procedure, Err) {
  any_read(id, client, resources.RtProcedure, resources.procedure_decoder())
}

pub fn procedure_update(
  resource: resources.Procedure,
  client: FhirClient,
) -> Result(resources.Procedure, Err) {
  any_update(
    resource.id,
    resources.procedure_to_json(resource),
    resources.RtProcedure,
    resources.procedure_decoder(),
    client,
  )
}

pub fn procedure_delete(
  resource: resources.Procedure,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtProcedure, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn provenance_create(
  resource: resources.Provenance,
  client: FhirClient,
) -> Result(resources.Provenance, Err) {
  any_create(
    resources.provenance_to_json(resource),
    resources.RtProvenance,
    resources.provenance_decoder(),
    client,
  )
}

pub fn provenance_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Provenance, Err) {
  any_read(id, client, resources.RtProvenance, resources.provenance_decoder())
}

pub fn provenance_update(
  resource: resources.Provenance,
  client: FhirClient,
) -> Result(resources.Provenance, Err) {
  any_update(
    resource.id,
    resources.provenance_to_json(resource),
    resources.RtProvenance,
    resources.provenance_decoder(),
    client,
  )
}

pub fn provenance_delete(
  resource: resources.Provenance,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtProvenance, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn questionnaire_create(
  resource: resources.Questionnaire,
  client: FhirClient,
) -> Result(resources.Questionnaire, Err) {
  any_create(
    resources.questionnaire_to_json(resource),
    resources.RtQuestionnaire,
    resources.questionnaire_decoder(),
    client,
  )
}

pub fn questionnaire_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Questionnaire, Err) {
  any_read(
    id,
    client,
    resources.RtQuestionnaire,
    resources.questionnaire_decoder(),
  )
}

pub fn questionnaire_update(
  resource: resources.Questionnaire,
  client: FhirClient,
) -> Result(resources.Questionnaire, Err) {
  any_update(
    resource.id,
    resources.questionnaire_to_json(resource),
    resources.RtQuestionnaire,
    resources.questionnaire_decoder(),
    client,
  )
}

pub fn questionnaire_delete(
  resource: resources.Questionnaire,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtQuestionnaire, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn questionnaireresponse_create(
  resource: resources.Questionnaireresponse,
  client: FhirClient,
) -> Result(resources.Questionnaireresponse, Err) {
  any_create(
    resources.questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.questionnaireresponse_decoder(),
    client,
  )
}

pub fn questionnaireresponse_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Questionnaireresponse, Err) {
  any_read(
    id,
    client,
    resources.RtQuestionnaireresponse,
    resources.questionnaireresponse_decoder(),
  )
}

pub fn questionnaireresponse_update(
  resource: resources.Questionnaireresponse,
  client: FhirClient,
) -> Result(resources.Questionnaireresponse, Err) {
  any_update(
    resource.id,
    resources.questionnaireresponse_to_json(resource),
    resources.RtQuestionnaireresponse,
    resources.questionnaireresponse_decoder(),
    client,
  )
}

pub fn questionnaireresponse_delete(
  resource: resources.Questionnaireresponse,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtQuestionnaireresponse, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn relatedperson_create(
  resource: resources.Relatedperson,
  client: FhirClient,
) -> Result(resources.Relatedperson, Err) {
  any_create(
    resources.relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.relatedperson_decoder(),
    client,
  )
}

pub fn relatedperson_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Relatedperson, Err) {
  any_read(
    id,
    client,
    resources.RtRelatedperson,
    resources.relatedperson_decoder(),
  )
}

pub fn relatedperson_update(
  resource: resources.Relatedperson,
  client: FhirClient,
) -> Result(resources.Relatedperson, Err) {
  any_update(
    resource.id,
    resources.relatedperson_to_json(resource),
    resources.RtRelatedperson,
    resources.relatedperson_decoder(),
    client,
  )
}

pub fn relatedperson_delete(
  resource: resources.Relatedperson,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtRelatedperson, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn requestgroup_create(
  resource: resources.Requestgroup,
  client: FhirClient,
) -> Result(resources.Requestgroup, Err) {
  any_create(
    resources.requestgroup_to_json(resource),
    resources.RtRequestgroup,
    resources.requestgroup_decoder(),
    client,
  )
}

pub fn requestgroup_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Requestgroup, Err) {
  any_read(
    id,
    client,
    resources.RtRequestgroup,
    resources.requestgroup_decoder(),
  )
}

pub fn requestgroup_update(
  resource: resources.Requestgroup,
  client: FhirClient,
) -> Result(resources.Requestgroup, Err) {
  any_update(
    resource.id,
    resources.requestgroup_to_json(resource),
    resources.RtRequestgroup,
    resources.requestgroup_decoder(),
    client,
  )
}

pub fn requestgroup_delete(
  resource: resources.Requestgroup,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtRequestgroup, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn researchdefinition_create(
  resource: resources.Researchdefinition,
  client: FhirClient,
) -> Result(resources.Researchdefinition, Err) {
  any_create(
    resources.researchdefinition_to_json(resource),
    resources.RtResearchdefinition,
    resources.researchdefinition_decoder(),
    client,
  )
}

pub fn researchdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Researchdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtResearchdefinition,
    resources.researchdefinition_decoder(),
  )
}

pub fn researchdefinition_update(
  resource: resources.Researchdefinition,
  client: FhirClient,
) -> Result(resources.Researchdefinition, Err) {
  any_update(
    resource.id,
    resources.researchdefinition_to_json(resource),
    resources.RtResearchdefinition,
    resources.researchdefinition_decoder(),
    client,
  )
}

pub fn researchdefinition_delete(
  resource: resources.Researchdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtResearchdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn researchelementdefinition_create(
  resource: resources.Researchelementdefinition,
  client: FhirClient,
) -> Result(resources.Researchelementdefinition, Err) {
  any_create(
    resources.researchelementdefinition_to_json(resource),
    resources.RtResearchelementdefinition,
    resources.researchelementdefinition_decoder(),
    client,
  )
}

pub fn researchelementdefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Researchelementdefinition, Err) {
  any_read(
    id,
    client,
    resources.RtResearchelementdefinition,
    resources.researchelementdefinition_decoder(),
  )
}

pub fn researchelementdefinition_update(
  resource: resources.Researchelementdefinition,
  client: FhirClient,
) -> Result(resources.Researchelementdefinition, Err) {
  any_update(
    resource.id,
    resources.researchelementdefinition_to_json(resource),
    resources.RtResearchelementdefinition,
    resources.researchelementdefinition_decoder(),
    client,
  )
}

pub fn researchelementdefinition_delete(
  resource: resources.Researchelementdefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtResearchelementdefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn researchstudy_create(
  resource: resources.Researchstudy,
  client: FhirClient,
) -> Result(resources.Researchstudy, Err) {
  any_create(
    resources.researchstudy_to_json(resource),
    resources.RtResearchstudy,
    resources.researchstudy_decoder(),
    client,
  )
}

pub fn researchstudy_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Researchstudy, Err) {
  any_read(
    id,
    client,
    resources.RtResearchstudy,
    resources.researchstudy_decoder(),
  )
}

pub fn researchstudy_update(
  resource: resources.Researchstudy,
  client: FhirClient,
) -> Result(resources.Researchstudy, Err) {
  any_update(
    resource.id,
    resources.researchstudy_to_json(resource),
    resources.RtResearchstudy,
    resources.researchstudy_decoder(),
    client,
  )
}

pub fn researchstudy_delete(
  resource: resources.Researchstudy,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtResearchstudy, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn researchsubject_create(
  resource: resources.Researchsubject,
  client: FhirClient,
) -> Result(resources.Researchsubject, Err) {
  any_create(
    resources.researchsubject_to_json(resource),
    resources.RtResearchsubject,
    resources.researchsubject_decoder(),
    client,
  )
}

pub fn researchsubject_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Researchsubject, Err) {
  any_read(
    id,
    client,
    resources.RtResearchsubject,
    resources.researchsubject_decoder(),
  )
}

pub fn researchsubject_update(
  resource: resources.Researchsubject,
  client: FhirClient,
) -> Result(resources.Researchsubject, Err) {
  any_update(
    resource.id,
    resources.researchsubject_to_json(resource),
    resources.RtResearchsubject,
    resources.researchsubject_decoder(),
    client,
  )
}

pub fn researchsubject_delete(
  resource: resources.Researchsubject,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtResearchsubject, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn riskassessment_create(
  resource: resources.Riskassessment,
  client: FhirClient,
) -> Result(resources.Riskassessment, Err) {
  any_create(
    resources.riskassessment_to_json(resource),
    resources.RtRiskassessment,
    resources.riskassessment_decoder(),
    client,
  )
}

pub fn riskassessment_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Riskassessment, Err) {
  any_read(
    id,
    client,
    resources.RtRiskassessment,
    resources.riskassessment_decoder(),
  )
}

pub fn riskassessment_update(
  resource: resources.Riskassessment,
  client: FhirClient,
) -> Result(resources.Riskassessment, Err) {
  any_update(
    resource.id,
    resources.riskassessment_to_json(resource),
    resources.RtRiskassessment,
    resources.riskassessment_decoder(),
    client,
  )
}

pub fn riskassessment_delete(
  resource: resources.Riskassessment,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtRiskassessment, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn riskevidencesynthesis_create(
  resource: resources.Riskevidencesynthesis,
  client: FhirClient,
) -> Result(resources.Riskevidencesynthesis, Err) {
  any_create(
    resources.riskevidencesynthesis_to_json(resource),
    resources.RtRiskevidencesynthesis,
    resources.riskevidencesynthesis_decoder(),
    client,
  )
}

pub fn riskevidencesynthesis_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Riskevidencesynthesis, Err) {
  any_read(
    id,
    client,
    resources.RtRiskevidencesynthesis,
    resources.riskevidencesynthesis_decoder(),
  )
}

pub fn riskevidencesynthesis_update(
  resource: resources.Riskevidencesynthesis,
  client: FhirClient,
) -> Result(resources.Riskevidencesynthesis, Err) {
  any_update(
    resource.id,
    resources.riskevidencesynthesis_to_json(resource),
    resources.RtRiskevidencesynthesis,
    resources.riskevidencesynthesis_decoder(),
    client,
  )
}

pub fn riskevidencesynthesis_delete(
  resource: resources.Riskevidencesynthesis,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtRiskevidencesynthesis, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn schedule_create(
  resource: resources.Schedule,
  client: FhirClient,
) -> Result(resources.Schedule, Err) {
  any_create(
    resources.schedule_to_json(resource),
    resources.RtSchedule,
    resources.schedule_decoder(),
    client,
  )
}

pub fn schedule_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Schedule, Err) {
  any_read(id, client, resources.RtSchedule, resources.schedule_decoder())
}

pub fn schedule_update(
  resource: resources.Schedule,
  client: FhirClient,
) -> Result(resources.Schedule, Err) {
  any_update(
    resource.id,
    resources.schedule_to_json(resource),
    resources.RtSchedule,
    resources.schedule_decoder(),
    client,
  )
}

pub fn schedule_delete(
  resource: resources.Schedule,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSchedule, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn searchparameter_create(
  resource: resources.Searchparameter,
  client: FhirClient,
) -> Result(resources.Searchparameter, Err) {
  any_create(
    resources.searchparameter_to_json(resource),
    resources.RtSearchparameter,
    resources.searchparameter_decoder(),
    client,
  )
}

pub fn searchparameter_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Searchparameter, Err) {
  any_read(
    id,
    client,
    resources.RtSearchparameter,
    resources.searchparameter_decoder(),
  )
}

pub fn searchparameter_update(
  resource: resources.Searchparameter,
  client: FhirClient,
) -> Result(resources.Searchparameter, Err) {
  any_update(
    resource.id,
    resources.searchparameter_to_json(resource),
    resources.RtSearchparameter,
    resources.searchparameter_decoder(),
    client,
  )
}

pub fn searchparameter_delete(
  resource: resources.Searchparameter,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSearchparameter, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn servicerequest_create(
  resource: resources.Servicerequest,
  client: FhirClient,
) -> Result(resources.Servicerequest, Err) {
  any_create(
    resources.servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.servicerequest_decoder(),
    client,
  )
}

pub fn servicerequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Servicerequest, Err) {
  any_read(
    id,
    client,
    resources.RtServicerequest,
    resources.servicerequest_decoder(),
  )
}

pub fn servicerequest_update(
  resource: resources.Servicerequest,
  client: FhirClient,
) -> Result(resources.Servicerequest, Err) {
  any_update(
    resource.id,
    resources.servicerequest_to_json(resource),
    resources.RtServicerequest,
    resources.servicerequest_decoder(),
    client,
  )
}

pub fn servicerequest_delete(
  resource: resources.Servicerequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtServicerequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn slot_create(
  resource: resources.Slot,
  client: FhirClient,
) -> Result(resources.Slot, Err) {
  any_create(
    resources.slot_to_json(resource),
    resources.RtSlot,
    resources.slot_decoder(),
    client,
  )
}

pub fn slot_read(id: String, client: FhirClient) -> Result(resources.Slot, Err) {
  any_read(id, client, resources.RtSlot, resources.slot_decoder())
}

pub fn slot_update(
  resource: resources.Slot,
  client: FhirClient,
) -> Result(resources.Slot, Err) {
  any_update(
    resource.id,
    resources.slot_to_json(resource),
    resources.RtSlot,
    resources.slot_decoder(),
    client,
  )
}

pub fn slot_delete(
  resource: resources.Slot,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSlot, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn specimen_create(
  resource: resources.Specimen,
  client: FhirClient,
) -> Result(resources.Specimen, Err) {
  any_create(
    resources.specimen_to_json(resource),
    resources.RtSpecimen,
    resources.specimen_decoder(),
    client,
  )
}

pub fn specimen_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Specimen, Err) {
  any_read(id, client, resources.RtSpecimen, resources.specimen_decoder())
}

pub fn specimen_update(
  resource: resources.Specimen,
  client: FhirClient,
) -> Result(resources.Specimen, Err) {
  any_update(
    resource.id,
    resources.specimen_to_json(resource),
    resources.RtSpecimen,
    resources.specimen_decoder(),
    client,
  )
}

pub fn specimen_delete(
  resource: resources.Specimen,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSpecimen, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn specimendefinition_create(
  resource: resources.Specimendefinition,
  client: FhirClient,
) -> Result(resources.Specimendefinition, Err) {
  any_create(
    resources.specimendefinition_to_json(resource),
    resources.RtSpecimendefinition,
    resources.specimendefinition_decoder(),
    client,
  )
}

pub fn specimendefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Specimendefinition, Err) {
  any_read(
    id,
    client,
    resources.RtSpecimendefinition,
    resources.specimendefinition_decoder(),
  )
}

pub fn specimendefinition_update(
  resource: resources.Specimendefinition,
  client: FhirClient,
) -> Result(resources.Specimendefinition, Err) {
  any_update(
    resource.id,
    resources.specimendefinition_to_json(resource),
    resources.RtSpecimendefinition,
    resources.specimendefinition_decoder(),
    client,
  )
}

pub fn specimendefinition_delete(
  resource: resources.Specimendefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSpecimendefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn structuredefinition_create(
  resource: resources.Structuredefinition,
  client: FhirClient,
) -> Result(resources.Structuredefinition, Err) {
  any_create(
    resources.structuredefinition_to_json(resource),
    resources.RtStructuredefinition,
    resources.structuredefinition_decoder(),
    client,
  )
}

pub fn structuredefinition_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Structuredefinition, Err) {
  any_read(
    id,
    client,
    resources.RtStructuredefinition,
    resources.structuredefinition_decoder(),
  )
}

pub fn structuredefinition_update(
  resource: resources.Structuredefinition,
  client: FhirClient,
) -> Result(resources.Structuredefinition, Err) {
  any_update(
    resource.id,
    resources.structuredefinition_to_json(resource),
    resources.RtStructuredefinition,
    resources.structuredefinition_decoder(),
    client,
  )
}

pub fn structuredefinition_delete(
  resource: resources.Structuredefinition,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtStructuredefinition, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn structuremap_create(
  resource: resources.Structuremap,
  client: FhirClient,
) -> Result(resources.Structuremap, Err) {
  any_create(
    resources.structuremap_to_json(resource),
    resources.RtStructuremap,
    resources.structuremap_decoder(),
    client,
  )
}

pub fn structuremap_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Structuremap, Err) {
  any_read(
    id,
    client,
    resources.RtStructuremap,
    resources.structuremap_decoder(),
  )
}

pub fn structuremap_update(
  resource: resources.Structuremap,
  client: FhirClient,
) -> Result(resources.Structuremap, Err) {
  any_update(
    resource.id,
    resources.structuremap_to_json(resource),
    resources.RtStructuremap,
    resources.structuremap_decoder(),
    client,
  )
}

pub fn structuremap_delete(
  resource: resources.Structuremap,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtStructuremap, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn subscription_create(
  resource: resources.Subscription,
  client: FhirClient,
) -> Result(resources.Subscription, Err) {
  any_create(
    resources.subscription_to_json(resource),
    resources.RtSubscription,
    resources.subscription_decoder(),
    client,
  )
}

pub fn subscription_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Subscription, Err) {
  any_read(
    id,
    client,
    resources.RtSubscription,
    resources.subscription_decoder(),
  )
}

pub fn subscription_update(
  resource: resources.Subscription,
  client: FhirClient,
) -> Result(resources.Subscription, Err) {
  any_update(
    resource.id,
    resources.subscription_to_json(resource),
    resources.RtSubscription,
    resources.subscription_decoder(),
    client,
  )
}

pub fn subscription_delete(
  resource: resources.Subscription,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSubscription, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn substance_create(
  resource: resources.Substance,
  client: FhirClient,
) -> Result(resources.Substance, Err) {
  any_create(
    resources.substance_to_json(resource),
    resources.RtSubstance,
    resources.substance_decoder(),
    client,
  )
}

pub fn substance_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Substance, Err) {
  any_read(id, client, resources.RtSubstance, resources.substance_decoder())
}

pub fn substance_update(
  resource: resources.Substance,
  client: FhirClient,
) -> Result(resources.Substance, Err) {
  any_update(
    resource.id,
    resources.substance_to_json(resource),
    resources.RtSubstance,
    resources.substance_decoder(),
    client,
  )
}

pub fn substance_delete(
  resource: resources.Substance,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSubstance, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn substancenucleicacid_create(
  resource: resources.Substancenucleicacid,
  client: FhirClient,
) -> Result(resources.Substancenucleicacid, Err) {
  any_create(
    resources.substancenucleicacid_to_json(resource),
    resources.RtSubstancenucleicacid,
    resources.substancenucleicacid_decoder(),
    client,
  )
}

pub fn substancenucleicacid_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Substancenucleicacid, Err) {
  any_read(
    id,
    client,
    resources.RtSubstancenucleicacid,
    resources.substancenucleicacid_decoder(),
  )
}

pub fn substancenucleicacid_update(
  resource: resources.Substancenucleicacid,
  client: FhirClient,
) -> Result(resources.Substancenucleicacid, Err) {
  any_update(
    resource.id,
    resources.substancenucleicacid_to_json(resource),
    resources.RtSubstancenucleicacid,
    resources.substancenucleicacid_decoder(),
    client,
  )
}

pub fn substancenucleicacid_delete(
  resource: resources.Substancenucleicacid,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSubstancenucleicacid, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn substancepolymer_create(
  resource: resources.Substancepolymer,
  client: FhirClient,
) -> Result(resources.Substancepolymer, Err) {
  any_create(
    resources.substancepolymer_to_json(resource),
    resources.RtSubstancepolymer,
    resources.substancepolymer_decoder(),
    client,
  )
}

pub fn substancepolymer_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Substancepolymer, Err) {
  any_read(
    id,
    client,
    resources.RtSubstancepolymer,
    resources.substancepolymer_decoder(),
  )
}

pub fn substancepolymer_update(
  resource: resources.Substancepolymer,
  client: FhirClient,
) -> Result(resources.Substancepolymer, Err) {
  any_update(
    resource.id,
    resources.substancepolymer_to_json(resource),
    resources.RtSubstancepolymer,
    resources.substancepolymer_decoder(),
    client,
  )
}

pub fn substancepolymer_delete(
  resource: resources.Substancepolymer,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSubstancepolymer, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn substanceprotein_create(
  resource: resources.Substanceprotein,
  client: FhirClient,
) -> Result(resources.Substanceprotein, Err) {
  any_create(
    resources.substanceprotein_to_json(resource),
    resources.RtSubstanceprotein,
    resources.substanceprotein_decoder(),
    client,
  )
}

pub fn substanceprotein_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Substanceprotein, Err) {
  any_read(
    id,
    client,
    resources.RtSubstanceprotein,
    resources.substanceprotein_decoder(),
  )
}

pub fn substanceprotein_update(
  resource: resources.Substanceprotein,
  client: FhirClient,
) -> Result(resources.Substanceprotein, Err) {
  any_update(
    resource.id,
    resources.substanceprotein_to_json(resource),
    resources.RtSubstanceprotein,
    resources.substanceprotein_decoder(),
    client,
  )
}

pub fn substanceprotein_delete(
  resource: resources.Substanceprotein,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSubstanceprotein, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn substancereferenceinformation_create(
  resource: resources.Substancereferenceinformation,
  client: FhirClient,
) -> Result(resources.Substancereferenceinformation, Err) {
  any_create(
    resources.substancereferenceinformation_to_json(resource),
    resources.RtSubstancereferenceinformation,
    resources.substancereferenceinformation_decoder(),
    client,
  )
}

pub fn substancereferenceinformation_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Substancereferenceinformation, Err) {
  any_read(
    id,
    client,
    resources.RtSubstancereferenceinformation,
    resources.substancereferenceinformation_decoder(),
  )
}

pub fn substancereferenceinformation_update(
  resource: resources.Substancereferenceinformation,
  client: FhirClient,
) -> Result(resources.Substancereferenceinformation, Err) {
  any_update(
    resource.id,
    resources.substancereferenceinformation_to_json(resource),
    resources.RtSubstancereferenceinformation,
    resources.substancereferenceinformation_decoder(),
    client,
  )
}

pub fn substancereferenceinformation_delete(
  resource: resources.Substancereferenceinformation,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) ->
      any_delete(id, resources.RtSubstancereferenceinformation, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn substancesourcematerial_create(
  resource: resources.Substancesourcematerial,
  client: FhirClient,
) -> Result(resources.Substancesourcematerial, Err) {
  any_create(
    resources.substancesourcematerial_to_json(resource),
    resources.RtSubstancesourcematerial,
    resources.substancesourcematerial_decoder(),
    client,
  )
}

pub fn substancesourcematerial_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Substancesourcematerial, Err) {
  any_read(
    id,
    client,
    resources.RtSubstancesourcematerial,
    resources.substancesourcematerial_decoder(),
  )
}

pub fn substancesourcematerial_update(
  resource: resources.Substancesourcematerial,
  client: FhirClient,
) -> Result(resources.Substancesourcematerial, Err) {
  any_update(
    resource.id,
    resources.substancesourcematerial_to_json(resource),
    resources.RtSubstancesourcematerial,
    resources.substancesourcematerial_decoder(),
    client,
  )
}

pub fn substancesourcematerial_delete(
  resource: resources.Substancesourcematerial,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSubstancesourcematerial, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn substancespecification_create(
  resource: resources.Substancespecification,
  client: FhirClient,
) -> Result(resources.Substancespecification, Err) {
  any_create(
    resources.substancespecification_to_json(resource),
    resources.RtSubstancespecification,
    resources.substancespecification_decoder(),
    client,
  )
}

pub fn substancespecification_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Substancespecification, Err) {
  any_read(
    id,
    client,
    resources.RtSubstancespecification,
    resources.substancespecification_decoder(),
  )
}

pub fn substancespecification_update(
  resource: resources.Substancespecification,
  client: FhirClient,
) -> Result(resources.Substancespecification, Err) {
  any_update(
    resource.id,
    resources.substancespecification_to_json(resource),
    resources.RtSubstancespecification,
    resources.substancespecification_decoder(),
    client,
  )
}

pub fn substancespecification_delete(
  resource: resources.Substancespecification,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSubstancespecification, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn supplydelivery_create(
  resource: resources.Supplydelivery,
  client: FhirClient,
) -> Result(resources.Supplydelivery, Err) {
  any_create(
    resources.supplydelivery_to_json(resource),
    resources.RtSupplydelivery,
    resources.supplydelivery_decoder(),
    client,
  )
}

pub fn supplydelivery_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Supplydelivery, Err) {
  any_read(
    id,
    client,
    resources.RtSupplydelivery,
    resources.supplydelivery_decoder(),
  )
}

pub fn supplydelivery_update(
  resource: resources.Supplydelivery,
  client: FhirClient,
) -> Result(resources.Supplydelivery, Err) {
  any_update(
    resource.id,
    resources.supplydelivery_to_json(resource),
    resources.RtSupplydelivery,
    resources.supplydelivery_decoder(),
    client,
  )
}

pub fn supplydelivery_delete(
  resource: resources.Supplydelivery,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSupplydelivery, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn supplyrequest_create(
  resource: resources.Supplyrequest,
  client: FhirClient,
) -> Result(resources.Supplyrequest, Err) {
  any_create(
    resources.supplyrequest_to_json(resource),
    resources.RtSupplyrequest,
    resources.supplyrequest_decoder(),
    client,
  )
}

pub fn supplyrequest_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Supplyrequest, Err) {
  any_read(
    id,
    client,
    resources.RtSupplyrequest,
    resources.supplyrequest_decoder(),
  )
}

pub fn supplyrequest_update(
  resource: resources.Supplyrequest,
  client: FhirClient,
) -> Result(resources.Supplyrequest, Err) {
  any_update(
    resource.id,
    resources.supplyrequest_to_json(resource),
    resources.RtSupplyrequest,
    resources.supplyrequest_decoder(),
    client,
  )
}

pub fn supplyrequest_delete(
  resource: resources.Supplyrequest,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtSupplyrequest, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn task_create(
  resource: resources.Task,
  client: FhirClient,
) -> Result(resources.Task, Err) {
  any_create(
    resources.task_to_json(resource),
    resources.RtTask,
    resources.task_decoder(),
    client,
  )
}

pub fn task_read(id: String, client: FhirClient) -> Result(resources.Task, Err) {
  any_read(id, client, resources.RtTask, resources.task_decoder())
}

pub fn task_update(
  resource: resources.Task,
  client: FhirClient,
) -> Result(resources.Task, Err) {
  any_update(
    resource.id,
    resources.task_to_json(resource),
    resources.RtTask,
    resources.task_decoder(),
    client,
  )
}

pub fn task_delete(
  resource: resources.Task,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtTask, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn terminologycapabilities_create(
  resource: resources.Terminologycapabilities,
  client: FhirClient,
) -> Result(resources.Terminologycapabilities, Err) {
  any_create(
    resources.terminologycapabilities_to_json(resource),
    resources.RtTerminologycapabilities,
    resources.terminologycapabilities_decoder(),
    client,
  )
}

pub fn terminologycapabilities_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Terminologycapabilities, Err) {
  any_read(
    id,
    client,
    resources.RtTerminologycapabilities,
    resources.terminologycapabilities_decoder(),
  )
}

pub fn terminologycapabilities_update(
  resource: resources.Terminologycapabilities,
  client: FhirClient,
) -> Result(resources.Terminologycapabilities, Err) {
  any_update(
    resource.id,
    resources.terminologycapabilities_to_json(resource),
    resources.RtTerminologycapabilities,
    resources.terminologycapabilities_decoder(),
    client,
  )
}

pub fn terminologycapabilities_delete(
  resource: resources.Terminologycapabilities,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtTerminologycapabilities, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn testreport_create(
  resource: resources.Testreport,
  client: FhirClient,
) -> Result(resources.Testreport, Err) {
  any_create(
    resources.testreport_to_json(resource),
    resources.RtTestreport,
    resources.testreport_decoder(),
    client,
  )
}

pub fn testreport_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Testreport, Err) {
  any_read(id, client, resources.RtTestreport, resources.testreport_decoder())
}

pub fn testreport_update(
  resource: resources.Testreport,
  client: FhirClient,
) -> Result(resources.Testreport, Err) {
  any_update(
    resource.id,
    resources.testreport_to_json(resource),
    resources.RtTestreport,
    resources.testreport_decoder(),
    client,
  )
}

pub fn testreport_delete(
  resource: resources.Testreport,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtTestreport, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn testscript_create(
  resource: resources.Testscript,
  client: FhirClient,
) -> Result(resources.Testscript, Err) {
  any_create(
    resources.testscript_to_json(resource),
    resources.RtTestscript,
    resources.testscript_decoder(),
    client,
  )
}

pub fn testscript_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Testscript, Err) {
  any_read(id, client, resources.RtTestscript, resources.testscript_decoder())
}

pub fn testscript_update(
  resource: resources.Testscript,
  client: FhirClient,
) -> Result(resources.Testscript, Err) {
  any_update(
    resource.id,
    resources.testscript_to_json(resource),
    resources.RtTestscript,
    resources.testscript_decoder(),
    client,
  )
}

pub fn testscript_delete(
  resource: resources.Testscript,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtTestscript, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn valueset_create(
  resource: resources.Valueset,
  client: FhirClient,
) -> Result(resources.Valueset, Err) {
  any_create(
    resources.valueset_to_json(resource),
    resources.RtValueset,
    resources.valueset_decoder(),
    client,
  )
}

pub fn valueset_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Valueset, Err) {
  any_read(id, client, resources.RtValueset, resources.valueset_decoder())
}

pub fn valueset_update(
  resource: resources.Valueset,
  client: FhirClient,
) -> Result(resources.Valueset, Err) {
  any_update(
    resource.id,
    resources.valueset_to_json(resource),
    resources.RtValueset,
    resources.valueset_decoder(),
    client,
  )
}

pub fn valueset_delete(
  resource: resources.Valueset,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtValueset, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn verificationresult_create(
  resource: resources.Verificationresult,
  client: FhirClient,
) -> Result(resources.Verificationresult, Err) {
  any_create(
    resources.verificationresult_to_json(resource),
    resources.RtVerificationresult,
    resources.verificationresult_decoder(),
    client,
  )
}

pub fn verificationresult_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Verificationresult, Err) {
  any_read(
    id,
    client,
    resources.RtVerificationresult,
    resources.verificationresult_decoder(),
  )
}

pub fn verificationresult_update(
  resource: resources.Verificationresult,
  client: FhirClient,
) -> Result(resources.Verificationresult, Err) {
  any_update(
    resource.id,
    resources.verificationresult_to_json(resource),
    resources.RtVerificationresult,
    resources.verificationresult_decoder(),
    client,
  )
}

pub fn verificationresult_delete(
  resource: resources.Verificationresult,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtVerificationresult, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn visionprescription_create(
  resource: resources.Visionprescription,
  client: FhirClient,
) -> Result(resources.Visionprescription, Err) {
  any_create(
    resources.visionprescription_to_json(resource),
    resources.RtVisionprescription,
    resources.visionprescription_decoder(),
    client,
  )
}

pub fn visionprescription_read(
  id: String,
  client: FhirClient,
) -> Result(resources.Visionprescription, Err) {
  any_read(
    id,
    client,
    resources.RtVisionprescription,
    resources.visionprescription_decoder(),
  )
}

pub fn visionprescription_update(
  resource: resources.Visionprescription,
  client: FhirClient,
) -> Result(resources.Visionprescription, Err) {
  any_update(
    resource.id,
    resources.visionprescription_to_json(resource),
    resources.RtVisionprescription,
    resources.visionprescription_decoder(),
    client,
  )
}

pub fn visionprescription_delete(
  resource: resources.Visionprescription,
  client: FhirClient,
) -> Result(sansio.OperationoutcomeOrHTTP, Err) {
  case resource.id {
    Some(id) -> any_delete(id, resources.RtVisionprescription, client)
    None -> Error(ErrSansio(ErrNoId))
  }
}

pub fn account_search_bundled(sp: search_params.Account, client: FhirClient) {
  search_params.to_string([
    #("owner", sp.owner),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("name", sp.name),
    #("type", sp.type_),
    #("status", sp.status),
  ])
  |> search_any(resources.RtAccount, client)
}

pub fn account_search(
  sp: search_params.Account,
  client: FhirClient,
) -> Result(List(resources.Account), Err) {
  case account_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.account)
    Error(error) -> Error(error)
  }
}

pub fn activitydefinition_search_bundled(
  sp: search_params.Activitydefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtActivitydefinition, client)
}

pub fn activitydefinition_search(
  sp: search_params.Activitydefinition,
  client: FhirClient,
) -> Result(List(resources.Activitydefinition), Err) {
  case activitydefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.activitydefinition)
    Error(error) -> Error(error)
  }
}

pub fn adverseevent_search_bundled(
  sp: search_params.Adverseevent,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("severity", sp.severity),
    #("recorder", sp.recorder),
    #("study", sp.study),
    #("actuality", sp.actuality),
    #("seriousness", sp.seriousness),
    #("subject", sp.subject),
    #("resultingcondition", sp.resultingcondition),
    #("substance", sp.substance),
    #("location", sp.location),
    #("category", sp.category),
    #("event", sp.event),
  ])
  |> search_any(resources.RtAdverseevent, client)
}

pub fn adverseevent_search(
  sp: search_params.Adverseevent,
  client: FhirClient,
) -> Result(List(resources.Adverseevent), Err) {
  case adverseevent_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.adverseevent)
    Error(error) -> Error(error)
  }
}

pub fn allergyintolerance_search_bundled(
  sp: search_params.Allergyintolerance,
  client: FhirClient,
) {
  search_params.to_string([
    #("severity", sp.severity),
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("manifestation", sp.manifestation),
    #("recorder", sp.recorder),
    #("code", sp.code),
    #("verification-status", sp.verification_status),
    #("criticality", sp.criticality),
    #("clinical-status", sp.clinical_status),
    #("type", sp.type_),
    #("onset", sp.onset),
    #("route", sp.route),
    #("asserter", sp.asserter),
    #("patient", sp.patient),
    #("category", sp.category),
    #("last-date", sp.last_date),
  ])
  |> search_any(resources.RtAllergyintolerance, client)
}

pub fn allergyintolerance_search(
  sp: search_params.Allergyintolerance,
  client: FhirClient,
) -> Result(List(resources.Allergyintolerance), Err) {
  case allergyintolerance_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.allergyintolerance)
    Error(error) -> Error(error)
  }
}

pub fn appointment_search_bundled(
  sp: search_params.Appointment,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("service-category", sp.service_category),
    #("practitioner", sp.practitioner),
    #("part-status", sp.part_status),
    #("appointment-type", sp.appointment_type),
    #("service-type", sp.service_type),
    #("slot", sp.slot),
    #("reason-code", sp.reason_code),
    #("actor", sp.actor),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("reason-reference", sp.reason_reference),
    #("supporting-info", sp.supporting_info),
    #("location", sp.location),
    #("status", sp.status),
  ])
  |> search_any(resources.RtAppointment, client)
}

pub fn appointment_search(
  sp: search_params.Appointment,
  client: FhirClient,
) -> Result(List(resources.Appointment), Err) {
  case appointment_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.appointment)
    Error(error) -> Error(error)
  }
}

pub fn appointmentresponse_search_bundled(
  sp: search_params.Appointmentresponse,
  client: FhirClient,
) {
  search_params.to_string([
    #("actor", sp.actor),
    #("identifier", sp.identifier),
    #("practitioner", sp.practitioner),
    #("part-status", sp.part_status),
    #("patient", sp.patient),
    #("appointment", sp.appointment),
    #("location", sp.location),
  ])
  |> search_any(resources.RtAppointmentresponse, client)
}

pub fn appointmentresponse_search(
  sp: search_params.Appointmentresponse,
  client: FhirClient,
) -> Result(List(resources.Appointmentresponse), Err) {
  case appointmentresponse_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.appointmentresponse)
    Error(error) -> Error(error)
  }
}

pub fn auditevent_search_bundled(
  sp: search_params.Auditevent,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("entity-type", sp.entity_type),
    #("agent", sp.agent),
    #("address", sp.address),
    #("entity-role", sp.entity_role),
    #("source", sp.source),
    #("type", sp.type_),
    #("altid", sp.altid),
    #("site", sp.site),
    #("agent-name", sp.agent_name),
    #("entity-name", sp.entity_name),
    #("subtype", sp.subtype),
    #("patient", sp.patient),
    #("action", sp.action),
    #("agent-role", sp.agent_role),
    #("entity", sp.entity),
    #("outcome", sp.outcome),
    #("policy", sp.policy),
  ])
  |> search_any(resources.RtAuditevent, client)
}

pub fn auditevent_search(
  sp: search_params.Auditevent,
  client: FhirClient,
) -> Result(List(resources.Auditevent), Err) {
  case auditevent_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.auditevent)
    Error(error) -> Error(error)
  }
}

pub fn basic_search_bundled(sp: search_params.Basic, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("subject", sp.subject),
    #("created", sp.created),
    #("patient", sp.patient),
    #("author", sp.author),
  ])
  |> search_any(resources.RtBasic, client)
}

pub fn basic_search(
  sp: search_params.Basic,
  client: FhirClient,
) -> Result(List(resources.Basic), Err) {
  case basic_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.basic)
    Error(error) -> Error(error)
  }
}

pub fn binary_search_bundled(_sp: search_params.Binary, client: FhirClient) {
  search_params.to_string([])
  |> search_any(resources.RtBinary, client)
}

pub fn binary_search(
  sp: search_params.Binary,
  client: FhirClient,
) -> Result(List(resources.Binary), Err) {
  case binary_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.binary)
    Error(error) -> Error(error)
  }
}

pub fn biologicallyderivedproduct_search_bundled(
  _sp: search_params.Biologicallyderivedproduct,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtBiologicallyderivedproduct, client)
}

pub fn biologicallyderivedproduct_search(
  sp: search_params.Biologicallyderivedproduct,
  client: FhirClient,
) -> Result(List(resources.Biologicallyderivedproduct), Err) {
  case biologicallyderivedproduct_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.biologicallyderivedproduct,
      )
    Error(error) -> Error(error)
  }
}

pub fn bodystructure_search_bundled(
  sp: search_params.Bodystructure,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("morphology", sp.morphology),
    #("patient", sp.patient),
    #("location", sp.location),
  ])
  |> search_any(resources.RtBodystructure, client)
}

pub fn bodystructure_search(
  sp: search_params.Bodystructure,
  client: FhirClient,
) -> Result(List(resources.Bodystructure), Err) {
  case bodystructure_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.bodystructure)
    Error(error) -> Error(error)
  }
}

pub fn bundle_search_bundled(sp: search_params.Bundle, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("composition", sp.composition),
    #("type", sp.type_),
    #("message", sp.message),
    #("timestamp", sp.timestamp),
  ])
  |> search_any(resources.RtBundle, client)
}

pub fn bundle_search(
  sp: search_params.Bundle,
  client: FhirClient,
) -> Result(List(resources.Bundle), Err) {
  case bundle_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.bundle)
    Error(error) -> Error(error)
  }
}

pub fn capabilitystatement_search_bundled(
  sp: search_params.Capabilitystatement,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("resource-profile", sp.resource_profile),
    #("context-type-value", sp.context_type_value),
    #("software", sp.software),
    #("resource", sp.resource),
    #("jurisdiction", sp.jurisdiction),
    #("format", sp.format),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("fhirversion", sp.fhirversion),
    #("version", sp.version),
    #("url", sp.url),
    #("supported-profile", sp.supported_profile),
    #("mode", sp.mode),
    #("context-quantity", sp.context_quantity),
    #("security-service", sp.security_service),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("guide", sp.guide),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCapabilitystatement, client)
}

pub fn capabilitystatement_search(
  sp: search_params.Capabilitystatement,
  client: FhirClient,
) -> Result(List(resources.Capabilitystatement), Err) {
  case capabilitystatement_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.capabilitystatement)
    Error(error) -> Error(error)
  }
}

pub fn careplan_search_bundled(sp: search_params.Careplan, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("care-team", sp.care_team),
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("goal", sp.goal),
    #("subject", sp.subject),
    #("replaces", sp.replaces),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("intent", sp.intent),
    #("activity-reference", sp.activity_reference),
    #("condition", sp.condition),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("activity-date", sp.activity_date),
    #("instantiates-uri", sp.instantiates_uri),
    #("category", sp.category),
    #("activity-code", sp.activity_code),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareplan, client)
}

pub fn careplan_search(
  sp: search_params.Careplan,
  client: FhirClient,
) -> Result(List(resources.Careplan), Err) {
  case careplan_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.careplan)
    Error(error) -> Error(error)
  }
}

pub fn careteam_search_bundled(sp: search_params.Careteam, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("category", sp.category),
    #("participant", sp.participant),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCareteam, client)
}

pub fn careteam_search(
  sp: search_params.Careteam,
  client: FhirClient,
) -> Result(List(resources.Careteam), Err) {
  case careteam_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.careteam)
    Error(error) -> Error(error)
  }
}

pub fn catalogentry_search_bundled(
  _sp: search_params.Catalogentry,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtCatalogentry, client)
}

pub fn catalogentry_search(
  sp: search_params.Catalogentry,
  client: FhirClient,
) -> Result(List(resources.Catalogentry), Err) {
  case catalogentry_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.catalogentry)
    Error(error) -> Error(error)
  }
}

pub fn chargeitem_search_bundled(
  sp: search_params.Chargeitem,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("performing-organization", sp.performing_organization),
    #("code", sp.code),
    #("quantity", sp.quantity),
    #("subject", sp.subject),
    #("occurrence", sp.occurrence),
    #("entered-date", sp.entered_date),
    #("performer-function", sp.performer_function),
    #("patient", sp.patient),
    #("factor-override", sp.factor_override),
    #("service", sp.service),
    #("price-override", sp.price_override),
    #("context", sp.context),
    #("enterer", sp.enterer),
    #("performer-actor", sp.performer_actor),
    #("account", sp.account),
    #("requesting-organization", sp.requesting_organization),
  ])
  |> search_any(resources.RtChargeitem, client)
}

pub fn chargeitem_search(
  sp: search_params.Chargeitem,
  client: FhirClient,
) -> Result(List(resources.Chargeitem), Err) {
  case chargeitem_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.chargeitem)
    Error(error) -> Error(error)
  }
}

pub fn chargeitemdefinition_search_bundled(
  sp: search_params.Chargeitemdefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtChargeitemdefinition, client)
}

pub fn chargeitemdefinition_search(
  sp: search_params.Chargeitemdefinition,
  client: FhirClient,
) -> Result(List(resources.Chargeitemdefinition), Err) {
  case chargeitemdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.chargeitemdefinition)
    Error(error) -> Error(error)
  }
}

pub fn claim_search_bundled(sp: search_params.Claim, client: FhirClient) {
  search_params.to_string([
    #("care-team", sp.care_team),
    #("identifier", sp.identifier),
    #("use", sp.use_),
    #("created", sp.created),
    #("encounter", sp.encounter),
    #("priority", sp.priority),
    #("payee", sp.payee),
    #("provider", sp.provider),
    #("patient", sp.patient),
    #("insurer", sp.insurer),
    #("detail-udi", sp.detail_udi),
    #("enterer", sp.enterer),
    #("procedure-udi", sp.procedure_udi),
    #("subdetail-udi", sp.subdetail_udi),
    #("facility", sp.facility),
    #("item-udi", sp.item_udi),
    #("status", sp.status),
  ])
  |> search_any(resources.RtClaim, client)
}

pub fn claim_search(
  sp: search_params.Claim,
  client: FhirClient,
) -> Result(List(resources.Claim), Err) {
  case claim_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.claim)
    Error(error) -> Error(error)
  }
}

pub fn claimresponse_search_bundled(
  sp: search_params.Claimresponse,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("disposition", sp.disposition),
    #("insurer", sp.insurer),
    #("created", sp.created),
    #("patient", sp.patient),
    #("use", sp.use_),
    #("payment-date", sp.payment_date),
    #("outcome", sp.outcome),
    #("requestor", sp.requestor),
    #("status", sp.status),
  ])
  |> search_any(resources.RtClaimresponse, client)
}

pub fn claimresponse_search(
  sp: search_params.Claimresponse,
  client: FhirClient,
) -> Result(List(resources.Claimresponse), Err) {
  case claimresponse_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.claimresponse)
    Error(error) -> Error(error)
  }
}

pub fn clinicalimpression_search_bundled(
  sp: search_params.Clinicalimpression,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("previous", sp.previous),
    #("finding-code", sp.finding_code),
    #("assessor", sp.assessor),
    #("subject", sp.subject),
    #("encounter", sp.encounter),
    #("finding-ref", sp.finding_ref),
    #("problem", sp.problem),
    #("patient", sp.patient),
    #("supporting-info", sp.supporting_info),
    #("investigation", sp.investigation),
    #("status", sp.status),
  ])
  |> search_any(resources.RtClinicalimpression, client)
}

pub fn clinicalimpression_search(
  sp: search_params.Clinicalimpression,
  client: FhirClient,
) -> Result(List(resources.Clinicalimpression), Err) {
  case clinicalimpression_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.clinicalimpression)
    Error(error) -> Error(error)
  }
}

pub fn codesystem_search_bundled(
  sp: search_params.Codesystem,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("content-mode", sp.content_mode),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("language", sp.language),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("supplements", sp.supplements),
    #("system", sp.system),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCodesystem, client)
}

pub fn codesystem_search(
  sp: search_params.Codesystem,
  client: FhirClient,
) -> Result(List(resources.Codesystem), Err) {
  case codesystem_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.codesystem)
    Error(error) -> Error(error)
  }
}

pub fn communication_search_bundled(
  sp: search_params.Communication,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("received", sp.received),
    #("part-of", sp.part_of),
    #("medium", sp.medium),
    #("encounter", sp.encounter),
    #("sent", sp.sent),
    #("based-on", sp.based_on),
    #("sender", sp.sender),
    #("patient", sp.patient),
    #("recipient", sp.recipient),
    #("instantiates-uri", sp.instantiates_uri),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCommunication, client)
}

pub fn communication_search(
  sp: search_params.Communication,
  client: FhirClient,
) -> Result(List(resources.Communication), Err) {
  case communication_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.communication)
    Error(error) -> Error(error)
  }
}

pub fn communicationrequest_search_bundled(
  sp: search_params.Communicationrequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("requester", sp.requester),
    #("authored", sp.authored),
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("replaces", sp.replaces),
    #("medium", sp.medium),
    #("encounter", sp.encounter),
    #("occurrence", sp.occurrence),
    #("priority", sp.priority),
    #("group-identifier", sp.group_identifier),
    #("based-on", sp.based_on),
    #("sender", sp.sender),
    #("patient", sp.patient),
    #("recipient", sp.recipient),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCommunicationrequest, client)
}

pub fn communicationrequest_search(
  sp: search_params.Communicationrequest,
  client: FhirClient,
) -> Result(List(resources.Communicationrequest), Err) {
  case communicationrequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.communicationrequest)
    Error(error) -> Error(error)
  }
}

pub fn compartmentdefinition_search_bundled(
  sp: search_params.Compartmentdefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("resource", sp.resource),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCompartmentdefinition, client)
}

pub fn compartmentdefinition_search(
  sp: search_params.Compartmentdefinition,
  client: FhirClient,
) -> Result(List(resources.Compartmentdefinition), Err) {
  case compartmentdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.compartmentdefinition)
    Error(error) -> Error(error)
  }
}

pub fn composition_search_bundled(
  sp: search_params.Composition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("related-id", sp.related_id),
    #("subject", sp.subject),
    #("author", sp.author),
    #("confidentiality", sp.confidentiality),
    #("section", sp.section),
    #("encounter", sp.encounter),
    #("type", sp.type_),
    #("title", sp.title),
    #("attester", sp.attester),
    #("entry", sp.entry),
    #("related-ref", sp.related_ref),
    #("patient", sp.patient),
    #("context", sp.context),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtComposition, client)
}

pub fn composition_search(
  sp: search_params.Composition,
  client: FhirClient,
) -> Result(List(resources.Composition), Err) {
  case composition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.composition)
    Error(error) -> Error(error)
  }
}

pub fn conceptmap_search_bundled(
  sp: search_params.Conceptmap,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("other", sp.other),
    #("context-type-value", sp.context_type_value),
    #("target-system", sp.target_system),
    #("dependson", sp.dependson),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("source", sp.source),
    #("title", sp.title),
    #("context-quantity", sp.context_quantity),
    #("source-uri", sp.source_uri),
    #("context", sp.context),
    #("context-type-quantity", sp.context_type_quantity),
    #("source-system", sp.source_system),
    #("target-code", sp.target_code),
    #("target-uri", sp.target_uri),
    #("identifier", sp.identifier),
    #("product", sp.product),
    #("version", sp.version),
    #("url", sp.url),
    #("target", sp.target),
    #("source-code", sp.source_code),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("status", sp.status),
  ])
  |> search_any(resources.RtConceptmap, client)
}

pub fn conceptmap_search(
  sp: search_params.Conceptmap,
  client: FhirClient,
) -> Result(List(resources.Conceptmap), Err) {
  case conceptmap_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.conceptmap)
    Error(error) -> Error(error)
  }
}

pub fn condition_search_bundled(sp: search_params.Condition, client: FhirClient) {
  search_params.to_string([
    #("severity", sp.severity),
    #("evidence-detail", sp.evidence_detail),
    #("identifier", sp.identifier),
    #("onset-info", sp.onset_info),
    #("recorded-date", sp.recorded_date),
    #("code", sp.code),
    #("evidence", sp.evidence),
    #("subject", sp.subject),
    #("verification-status", sp.verification_status),
    #("clinical-status", sp.clinical_status),
    #("encounter", sp.encounter),
    #("onset-date", sp.onset_date),
    #("abatement-date", sp.abatement_date),
    #("asserter", sp.asserter),
    #("stage", sp.stage),
    #("abatement-string", sp.abatement_string),
    #("patient", sp.patient),
    #("onset-age", sp.onset_age),
    #("abatement-age", sp.abatement_age),
    #("category", sp.category),
    #("body-site", sp.body_site),
  ])
  |> search_any(resources.RtCondition, client)
}

pub fn condition_search(
  sp: search_params.Condition,
  client: FhirClient,
) -> Result(List(resources.Condition), Err) {
  case condition_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.condition)
    Error(error) -> Error(error)
  }
}

pub fn consent_search_bundled(sp: search_params.Consent, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("data", sp.data),
    #("purpose", sp.purpose),
    #("source-reference", sp.source_reference),
    #("actor", sp.actor),
    #("security-label", sp.security_label),
    #("patient", sp.patient),
    #("organization", sp.organization),
    #("scope", sp.scope),
    #("action", sp.action),
    #("consentor", sp.consentor),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtConsent, client)
}

pub fn consent_search(
  sp: search_params.Consent,
  client: FhirClient,
) -> Result(List(resources.Consent), Err) {
  case consent_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.consent)
    Error(error) -> Error(error)
  }
}

pub fn contract_search_bundled(sp: search_params.Contract, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("instantiates", sp.instantiates),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("authority", sp.authority),
    #("domain", sp.domain),
    #("issued", sp.issued),
    #("url", sp.url),
    #("signer", sp.signer),
    #("status", sp.status),
  ])
  |> search_any(resources.RtContract, client)
}

pub fn contract_search(
  sp: search_params.Contract,
  client: FhirClient,
) -> Result(List(resources.Contract), Err) {
  case contract_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.contract)
    Error(error) -> Error(error)
  }
}

pub fn coverage_search_bundled(sp: search_params.Coverage, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("payor", sp.payor),
    #("subscriber", sp.subscriber),
    #("beneficiary", sp.beneficiary),
    #("patient", sp.patient),
    #("class-value", sp.class_value),
    #("type", sp.type_),
    #("dependent", sp.dependent),
    #("class-type", sp.class_type),
    #("policy-holder", sp.policy_holder),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCoverage, client)
}

pub fn coverage_search(
  sp: search_params.Coverage,
  client: FhirClient,
) -> Result(List(resources.Coverage), Err) {
  case coverage_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.coverage)
    Error(error) -> Error(error)
  }
}

pub fn coverageeligibilityrequest_search_bundled(
  sp: search_params.Coverageeligibilityrequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("provider", sp.provider),
    #("patient", sp.patient),
    #("created", sp.created),
    #("enterer", sp.enterer),
    #("facility", sp.facility),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCoverageeligibilityrequest, client)
}

pub fn coverageeligibilityrequest_search(
  sp: search_params.Coverageeligibilityrequest,
  client: FhirClient,
) -> Result(List(resources.Coverageeligibilityrequest), Err) {
  case coverageeligibilityrequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.coverageeligibilityrequest,
      )
    Error(error) -> Error(error)
  }
}

pub fn coverageeligibilityresponse_search_bundled(
  sp: search_params.Coverageeligibilityresponse,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("disposition", sp.disposition),
    #("patient", sp.patient),
    #("insurer", sp.insurer),
    #("created", sp.created),
    #("outcome", sp.outcome),
    #("requestor", sp.requestor),
    #("status", sp.status),
  ])
  |> search_any(resources.RtCoverageeligibilityresponse, client)
}

pub fn coverageeligibilityresponse_search(
  sp: search_params.Coverageeligibilityresponse,
  client: FhirClient,
) -> Result(List(resources.Coverageeligibilityresponse), Err) {
  case coverageeligibilityresponse_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.coverageeligibilityresponse,
      )
    Error(error) -> Error(error)
  }
}

pub fn detectedissue_search_bundled(
  sp: search_params.Detectedissue,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("identified", sp.identified),
    #("patient", sp.patient),
    #("author", sp.author),
    #("implicated", sp.implicated),
  ])
  |> search_any(resources.RtDetectedissue, client)
}

pub fn detectedissue_search(
  sp: search_params.Detectedissue,
  client: FhirClient,
) -> Result(List(resources.Detectedissue), Err) {
  case detectedissue_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.detectedissue)
    Error(error) -> Error(error)
  }
}

pub fn device_search_bundled(sp: search_params.Device, client: FhirClient) {
  search_params.to_string([
    #("udi-di", sp.udi_di),
    #("identifier", sp.identifier),
    #("udi-carrier", sp.udi_carrier),
    #("device-name", sp.device_name),
    #("patient", sp.patient),
    #("organization", sp.organization),
    #("model", sp.model),
    #("location", sp.location),
    #("type", sp.type_),
    #("url", sp.url),
    #("manufacturer", sp.manufacturer),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDevice, client)
}

pub fn device_search(
  sp: search_params.Device,
  client: FhirClient,
) -> Result(List(resources.Device), Err) {
  case device_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.device)
    Error(error) -> Error(error)
  }
}

pub fn devicedefinition_search_bundled(
  sp: search_params.Devicedefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("parent", sp.parent),
    #("identifier", sp.identifier),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtDevicedefinition, client)
}

pub fn devicedefinition_search(
  sp: search_params.Devicedefinition,
  client: FhirClient,
) -> Result(List(resources.Devicedefinition), Err) {
  case devicedefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.devicedefinition)
    Error(error) -> Error(error)
  }
}

pub fn devicemetric_search_bundled(
  sp: search_params.Devicemetric,
  client: FhirClient,
) {
  search_params.to_string([
    #("parent", sp.parent),
    #("identifier", sp.identifier),
    #("source", sp.source),
    #("type", sp.type_),
    #("category", sp.category),
  ])
  |> search_any(resources.RtDevicemetric, client)
}

pub fn devicemetric_search(
  sp: search_params.Devicemetric,
  client: FhirClient,
) -> Result(List(resources.Devicemetric), Err) {
  case devicemetric_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.devicemetric)
    Error(error) -> Error(error)
  }
}

pub fn devicerequest_search_bundled(
  sp: search_params.Devicerequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("requester", sp.requester),
    #("insurance", sp.insurance),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("performer", sp.performer),
    #("event-date", sp.event_date),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("encounter", sp.encounter),
    #("authored-on", sp.authored_on),
    #("intent", sp.intent),
    #("group-identifier", sp.group_identifier),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("instantiates-uri", sp.instantiates_uri),
    #("prior-request", sp.prior_request),
    #("device", sp.device),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDevicerequest, client)
}

pub fn devicerequest_search(
  sp: search_params.Devicerequest,
  client: FhirClient,
) -> Result(List(resources.Devicerequest), Err) {
  case devicerequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.devicerequest)
    Error(error) -> Error(error)
  }
}

pub fn deviceusestatement_search_bundled(
  sp: search_params.Deviceusestatement,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("device", sp.device),
  ])
  |> search_any(resources.RtDeviceusestatement, client)
}

pub fn deviceusestatement_search(
  sp: search_params.Deviceusestatement,
  client: FhirClient,
) -> Result(List(resources.Deviceusestatement), Err) {
  case deviceusestatement_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.deviceusestatement)
    Error(error) -> Error(error)
  }
}

pub fn diagnosticreport_search_bundled(
  sp: search_params.Diagnosticreport,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("code", sp.code),
    #("subject", sp.subject),
    #("media", sp.media),
    #("encounter", sp.encounter),
    #("result", sp.result),
    #("conclusion", sp.conclusion),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("specimen", sp.specimen),
    #("issued", sp.issued),
    #("category", sp.category),
    #("results-interpreter", sp.results_interpreter),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDiagnosticreport, client)
}

pub fn diagnosticreport_search(
  sp: search_params.Diagnosticreport,
  client: FhirClient,
) -> Result(List(resources.Diagnosticreport), Err) {
  case diagnosticreport_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.diagnosticreport)
    Error(error) -> Error(error)
  }
}

pub fn documentmanifest_search_bundled(
  sp: search_params.Documentmanifest,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("item", sp.item),
    #("related-id", sp.related_id),
    #("subject", sp.subject),
    #("author", sp.author),
    #("created", sp.created),
    #("description", sp.description),
    #("source", sp.source),
    #("type", sp.type_),
    #("related-ref", sp.related_ref),
    #("patient", sp.patient),
    #("recipient", sp.recipient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDocumentmanifest, client)
}

pub fn documentmanifest_search(
  sp: search_params.Documentmanifest,
  client: FhirClient,
) -> Result(List(resources.Documentmanifest), Err) {
  case documentmanifest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.documentmanifest)
    Error(error) -> Error(error)
  }
}

pub fn documentreference_search_bundled(
  sp: search_params.Documentreference,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("subject", sp.subject),
    #("description", sp.description),
    #("language", sp.language),
    #("type", sp.type_),
    #("relation", sp.relation),
    #("setting", sp.setting),
    #("related", sp.related),
    #("patient", sp.patient),
    #("relationship", sp.relationship),
    #("event", sp.event),
    #("authenticator", sp.authenticator),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("custodian", sp.custodian),
    #("author", sp.author),
    #("format", sp.format),
    #("encounter", sp.encounter),
    #("contenttype", sp.contenttype),
    #("security-label", sp.security_label),
    #("location", sp.location),
    #("category", sp.category),
    #("relatesto", sp.relatesto),
    #("facility", sp.facility),
    #("status", sp.status),
  ])
  |> search_any(resources.RtDocumentreference, client)
}

pub fn documentreference_search(
  sp: search_params.Documentreference,
  client: FhirClient,
) -> Result(List(resources.Documentreference), Err) {
  case documentreference_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.documentreference)
    Error(error) -> Error(error)
  }
}

pub fn effectevidencesynthesis_search_bundled(
  sp: search_params.Effectevidencesynthesis,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEffectevidencesynthesis, client)
}

pub fn effectevidencesynthesis_search(
  sp: search_params.Effectevidencesynthesis,
  client: FhirClient,
) -> Result(List(resources.Effectevidencesynthesis), Err) {
  case effectevidencesynthesis_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.effectevidencesynthesis,
      )
    Error(error) -> Error(error)
  }
}

pub fn encounter_search_bundled(sp: search_params.Encounter, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("participant-type", sp.participant_type),
    #("practitioner", sp.practitioner),
    #("subject", sp.subject),
    #("length", sp.length),
    #("episode-of-care", sp.episode_of_care),
    #("diagnosis", sp.diagnosis),
    #("appointment", sp.appointment),
    #("part-of", sp.part_of),
    #("type", sp.type_),
    #("reason-code", sp.reason_code),
    #("participant", sp.participant),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("reason-reference", sp.reason_reference),
    #("location-period", sp.location_period),
    #("location", sp.location),
    #("service-provider", sp.service_provider),
    #("special-arrangement", sp.special_arrangement),
    #("class", sp.class),
    #("account", sp.account),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEncounter, client)
}

pub fn encounter_search(
  sp: search_params.Encounter,
  client: FhirClient,
) -> Result(List(resources.Encounter), Err) {
  case encounter_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.encounter)
    Error(error) -> Error(error)
  }
}

pub fn endpoint_search_bundled(sp: search_params.Endpoint, client: FhirClient) {
  search_params.to_string([
    #("payload-type", sp.payload_type),
    #("identifier", sp.identifier),
    #("organization", sp.organization),
    #("connection-type", sp.connection_type),
    #("name", sp.name),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEndpoint, client)
}

pub fn endpoint_search(
  sp: search_params.Endpoint,
  client: FhirClient,
) -> Result(List(resources.Endpoint), Err) {
  case endpoint_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.endpoint)
    Error(error) -> Error(error)
  }
}

pub fn enrollmentrequest_search_bundled(
  sp: search_params.Enrollmentrequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEnrollmentrequest, client)
}

pub fn enrollmentrequest_search(
  sp: search_params.Enrollmentrequest,
  client: FhirClient,
) -> Result(List(resources.Enrollmentrequest), Err) {
  case enrollmentrequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.enrollmentrequest)
    Error(error) -> Error(error)
  }
}

pub fn enrollmentresponse_search_bundled(
  sp: search_params.Enrollmentresponse,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEnrollmentresponse, client)
}

pub fn enrollmentresponse_search(
  sp: search_params.Enrollmentresponse,
  client: FhirClient,
) -> Result(List(resources.Enrollmentresponse), Err) {
  case enrollmentresponse_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.enrollmentresponse)
    Error(error) -> Error(error)
  }
}

pub fn episodeofcare_search_bundled(
  sp: search_params.Episodeofcare,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("condition", sp.condition),
    #("patient", sp.patient),
    #("organization", sp.organization),
    #("type", sp.type_),
    #("care-manager", sp.care_manager),
    #("status", sp.status),
    #("incoming-referral", sp.incoming_referral),
  ])
  |> search_any(resources.RtEpisodeofcare, client)
}

pub fn episodeofcare_search(
  sp: search_params.Episodeofcare,
  client: FhirClient,
) -> Result(List(resources.Episodeofcare), Err) {
  case episodeofcare_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.episodeofcare)
    Error(error) -> Error(error)
  }
}

pub fn eventdefinition_search_bundled(
  sp: search_params.Eventdefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEventdefinition, client)
}

pub fn eventdefinition_search(
  sp: search_params.Eventdefinition,
  client: FhirClient,
) -> Result(List(resources.Eventdefinition), Err) {
  case eventdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.eventdefinition)
    Error(error) -> Error(error)
  }
}

pub fn evidence_search_bundled(sp: search_params.Evidence, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEvidence, client)
}

pub fn evidence_search(
  sp: search_params.Evidence,
  client: FhirClient,
) -> Result(List(resources.Evidence), Err) {
  case evidence_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.evidence)
    Error(error) -> Error(error)
  }
}

pub fn evidencevariable_search_bundled(
  sp: search_params.Evidencevariable,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtEvidencevariable, client)
}

pub fn evidencevariable_search(
  sp: search_params.Evidencevariable,
  client: FhirClient,
) -> Result(List(resources.Evidencevariable), Err) {
  case evidencevariable_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.evidencevariable)
    Error(error) -> Error(error)
  }
}

pub fn examplescenario_search_bundled(
  sp: search_params.Examplescenario,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("context-type", sp.context_type),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtExamplescenario, client)
}

pub fn examplescenario_search(
  sp: search_params.Examplescenario,
  client: FhirClient,
) -> Result(List(resources.Examplescenario), Err) {
  case examplescenario_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.examplescenario)
    Error(error) -> Error(error)
  }
}

pub fn explanationofbenefit_search_bundled(
  sp: search_params.Explanationofbenefit,
  client: FhirClient,
) {
  search_params.to_string([
    #("coverage", sp.coverage),
    #("care-team", sp.care_team),
    #("identifier", sp.identifier),
    #("created", sp.created),
    #("encounter", sp.encounter),
    #("payee", sp.payee),
    #("disposition", sp.disposition),
    #("provider", sp.provider),
    #("patient", sp.patient),
    #("detail-udi", sp.detail_udi),
    #("claim", sp.claim),
    #("enterer", sp.enterer),
    #("procedure-udi", sp.procedure_udi),
    #("subdetail-udi", sp.subdetail_udi),
    #("facility", sp.facility),
    #("item-udi", sp.item_udi),
    #("status", sp.status),
  ])
  |> search_any(resources.RtExplanationofbenefit, client)
}

pub fn explanationofbenefit_search(
  sp: search_params.Explanationofbenefit,
  client: FhirClient,
) -> Result(List(resources.Explanationofbenefit), Err) {
  case explanationofbenefit_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.explanationofbenefit)
    Error(error) -> Error(error)
  }
}

pub fn familymemberhistory_search_bundled(
  sp: search_params.Familymemberhistory,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("patient", sp.patient),
    #("sex", sp.sex),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("instantiates-uri", sp.instantiates_uri),
    #("relationship", sp.relationship),
    #("status", sp.status),
  ])
  |> search_any(resources.RtFamilymemberhistory, client)
}

pub fn familymemberhistory_search(
  sp: search_params.Familymemberhistory,
  client: FhirClient,
) -> Result(List(resources.Familymemberhistory), Err) {
  case familymemberhistory_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.familymemberhistory)
    Error(error) -> Error(error)
  }
}

pub fn flag_search_bundled(sp: search_params.Flag, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("author", sp.author),
    #("encounter", sp.encounter),
  ])
  |> search_any(resources.RtFlag, client)
}

pub fn flag_search(
  sp: search_params.Flag,
  client: FhirClient,
) -> Result(List(resources.Flag), Err) {
  case flag_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.flag)
    Error(error) -> Error(error)
  }
}

pub fn goal_search_bundled(sp: search_params.Goal, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("lifecycle-status", sp.lifecycle_status),
    #("achievement-status", sp.achievement_status),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("start-date", sp.start_date),
    #("category", sp.category),
    #("target-date", sp.target_date),
  ])
  |> search_any(resources.RtGoal, client)
}

pub fn goal_search(
  sp: search_params.Goal,
  client: FhirClient,
) -> Result(List(resources.Goal), Err) {
  case goal_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.goal)
    Error(error) -> Error(error)
  }
}

pub fn graphdefinition_search_bundled(
  sp: search_params.Graphdefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("start", sp.start),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtGraphdefinition, client)
}

pub fn graphdefinition_search(
  sp: search_params.Graphdefinition,
  client: FhirClient,
) -> Result(List(resources.Graphdefinition), Err) {
  case graphdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.graphdefinition)
    Error(error) -> Error(error)
  }
}

pub fn group_search_bundled(sp: search_params.Group, client: FhirClient) {
  search_params.to_string([
    #("actual", sp.actual),
    #("identifier", sp.identifier),
    #("characteristic-value", sp.characteristic_value),
    #("managing-entity", sp.managing_entity),
    #("code", sp.code),
    #("member", sp.member),
    #("exclude", sp.exclude),
    #("type", sp.type_),
    #("value", sp.value),
    #("characteristic", sp.characteristic),
  ])
  |> search_any(resources.RtGroup, client)
}

pub fn group_search(
  sp: search_params.Group,
  client: FhirClient,
) -> Result(List(resources.Group), Err) {
  case group_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.group)
    Error(error) -> Error(error)
  }
}

pub fn guidanceresponse_search_bundled(
  sp: search_params.Guidanceresponse,
  client: FhirClient,
) {
  search_params.to_string([
    #("request", sp.request),
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("subject", sp.subject),
  ])
  |> search_any(resources.RtGuidanceresponse, client)
}

pub fn guidanceresponse_search(
  sp: search_params.Guidanceresponse,
  client: FhirClient,
) -> Result(List(resources.Guidanceresponse), Err) {
  case guidanceresponse_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.guidanceresponse)
    Error(error) -> Error(error)
  }
}

pub fn healthcareservice_search_bundled(
  sp: search_params.Healthcareservice,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("endpoint", sp.endpoint),
    #("service-category", sp.service_category),
    #("coverage-area", sp.coverage_area),
    #("service-type", sp.service_type),
    #("organization", sp.organization),
    #("name", sp.name),
    #("active", sp.active),
    #("location", sp.location),
    #("program", sp.program),
    #("characteristic", sp.characteristic),
  ])
  |> search_any(resources.RtHealthcareservice, client)
}

pub fn healthcareservice_search(
  sp: search_params.Healthcareservice,
  client: FhirClient,
) -> Result(List(resources.Healthcareservice), Err) {
  case healthcareservice_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.healthcareservice)
    Error(error) -> Error(error)
  }
}

pub fn imagingstudy_search_bundled(
  sp: search_params.Imagingstudy,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("reason", sp.reason),
    #("dicom-class", sp.dicom_class),
    #("modality", sp.modality),
    #("bodysite", sp.bodysite),
    #("instance", sp.instance),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("started", sp.started),
    #("interpreter", sp.interpreter),
    #("encounter", sp.encounter),
    #("referrer", sp.referrer),
    #("endpoint", sp.endpoint),
    #("patient", sp.patient),
    #("series", sp.series),
    #("basedon", sp.basedon),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImagingstudy, client)
}

pub fn imagingstudy_search(
  sp: search_params.Imagingstudy,
  client: FhirClient,
) -> Result(List(resources.Imagingstudy), Err) {
  case imagingstudy_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.imagingstudy)
    Error(error) -> Error(error)
  }
}

pub fn immunization_search_bundled(
  sp: search_params.Immunization,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("reaction", sp.reaction),
    #("lot-number", sp.lot_number),
    #("status-reason", sp.status_reason),
    #("reason-code", sp.reason_code),
    #("manufacturer", sp.manufacturer),
    #("target-disease", sp.target_disease),
    #("patient", sp.patient),
    #("series", sp.series),
    #("vaccine-code", sp.vaccine_code),
    #("reason-reference", sp.reason_reference),
    #("location", sp.location),
    #("status", sp.status),
    #("reaction-date", sp.reaction_date),
  ])
  |> search_any(resources.RtImmunization, client)
}

pub fn immunization_search(
  sp: search_params.Immunization,
  client: FhirClient,
) -> Result(List(resources.Immunization), Err) {
  case immunization_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.immunization)
    Error(error) -> Error(error)
  }
}

pub fn immunizationevaluation_search_bundled(
  sp: search_params.Immunizationevaluation,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("target-disease", sp.target_disease),
    #("patient", sp.patient),
    #("dose-status", sp.dose_status),
    #("immunization-event", sp.immunization_event),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImmunizationevaluation, client)
}

pub fn immunizationevaluation_search(
  sp: search_params.Immunizationevaluation,
  client: FhirClient,
) -> Result(List(resources.Immunizationevaluation), Err) {
  case immunizationevaluation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.immunizationevaluation)
    Error(error) -> Error(error)
  }
}

pub fn immunizationrecommendation_search_bundled(
  sp: search_params.Immunizationrecommendation,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("target-disease", sp.target_disease),
    #("patient", sp.patient),
    #("vaccine-type", sp.vaccine_type),
    #("information", sp.information),
    #("support", sp.support),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImmunizationrecommendation, client)
}

pub fn immunizationrecommendation_search(
  sp: search_params.Immunizationrecommendation,
  client: FhirClient,
) -> Result(List(resources.Immunizationrecommendation), Err) {
  case immunizationrecommendation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.immunizationrecommendation,
      )
    Error(error) -> Error(error)
  }
}

pub fn implementationguide_search_bundled(
  sp: search_params.Implementationguide,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("context-type-value", sp.context_type_value),
    #("resource", sp.resource),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("experimental", sp.experimental),
    #("global", sp.global),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtImplementationguide, client)
}

pub fn implementationguide_search(
  sp: search_params.Implementationguide,
  client: FhirClient,
) -> Result(List(resources.Implementationguide), Err) {
  case implementationguide_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.implementationguide)
    Error(error) -> Error(error)
  }
}

pub fn insuranceplan_search_bundled(
  sp: search_params.Insuranceplan,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("address", sp.address),
    #("address-state", sp.address_state),
    #("owned-by", sp.owned_by),
    #("type", sp.type_),
    #("address-postalcode", sp.address_postalcode),
    #("administered-by", sp.administered_by),
    #("address-country", sp.address_country),
    #("endpoint", sp.endpoint),
    #("phonetic", sp.phonetic),
    #("name", sp.name),
    #("address-use", sp.address_use),
    #("address-city", sp.address_city),
    #("status", sp.status),
  ])
  |> search_any(resources.RtInsuranceplan, client)
}

pub fn insuranceplan_search(
  sp: search_params.Insuranceplan,
  client: FhirClient,
) -> Result(List(resources.Insuranceplan), Err) {
  case insuranceplan_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.insuranceplan)
    Error(error) -> Error(error)
  }
}

pub fn invoice_search_bundled(sp: search_params.Invoice, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("totalgross", sp.totalgross),
    #("subject", sp.subject),
    #("participant-role", sp.participant_role),
    #("type", sp.type_),
    #("issuer", sp.issuer),
    #("participant", sp.participant),
    #("totalnet", sp.totalnet),
    #("patient", sp.patient),
    #("recipient", sp.recipient),
    #("account", sp.account),
    #("status", sp.status),
  ])
  |> search_any(resources.RtInvoice, client)
}

pub fn invoice_search(
  sp: search_params.Invoice,
  client: FhirClient,
) -> Result(List(resources.Invoice), Err) {
  case invoice_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.invoice)
    Error(error) -> Error(error)
  }
}

pub fn library_search_bundled(sp: search_params.Library, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("content-type", sp.content_type),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtLibrary, client)
}

pub fn library_search(
  sp: search_params.Library,
  client: FhirClient,
) -> Result(List(resources.Library), Err) {
  case library_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.library)
    Error(error) -> Error(error)
  }
}

pub fn linkage_search_bundled(sp: search_params.Linkage, client: FhirClient) {
  search_params.to_string([
    #("item", sp.item),
    #("author", sp.author),
    #("source", sp.source),
  ])
  |> search_any(resources.RtLinkage, client)
}

pub fn linkage_search(
  sp: search_params.Linkage,
  client: FhirClient,
) -> Result(List(resources.Linkage), Err) {
  case linkage_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.linkage)
    Error(error) -> Error(error)
  }
}

pub fn listfhir_search_bundled(sp: search_params.Listfhir, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("item", sp.item),
    #("empty-reason", sp.empty_reason),
    #("code", sp.code),
    #("notes", sp.notes),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("source", sp.source),
    #("encounter", sp.encounter),
    #("title", sp.title),
    #("status", sp.status),
  ])
  |> search_any(resources.RtListfhir, client)
}

pub fn listfhir_search(
  sp: search_params.Listfhir,
  client: FhirClient,
) -> Result(List(resources.Listfhir), Err) {
  case listfhir_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.listfhir)
    Error(error) -> Error(error)
  }
}

pub fn location_search_bundled(sp: search_params.Location, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("partof", sp.partof),
    #("address", sp.address),
    #("address-state", sp.address_state),
    #("operational-status", sp.operational_status),
    #("type", sp.type_),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("endpoint", sp.endpoint),
    #("organization", sp.organization),
    #("name", sp.name),
    #("address-use", sp.address_use),
    #("near", sp.near),
    #("address-city", sp.address_city),
    #("status", sp.status),
  ])
  |> search_any(resources.RtLocation, client)
}

pub fn location_search(
  sp: search_params.Location,
  client: FhirClient,
) -> Result(List(resources.Location), Err) {
  case location_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.location)
    Error(error) -> Error(error)
  }
}

pub fn measure_search_bundled(sp: search_params.Measure, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMeasure, client)
}

pub fn measure_search(
  sp: search_params.Measure,
  client: FhirClient,
) -> Result(List(resources.Measure), Err) {
  case measure_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.measure)
    Error(error) -> Error(error)
  }
}

pub fn measurereport_search_bundled(
  sp: search_params.Measurereport,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("period", sp.period),
    #("measure", sp.measure),
    #("patient", sp.patient),
    #("subject", sp.subject),
    #("reporter", sp.reporter),
    #("status", sp.status),
    #("evaluated-resource", sp.evaluated_resource),
  ])
  |> search_any(resources.RtMeasurereport, client)
}

pub fn measurereport_search(
  sp: search_params.Measurereport,
  client: FhirClient,
) -> Result(List(resources.Measurereport), Err) {
  case measurereport_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.measurereport)
    Error(error) -> Error(error)
  }
}

pub fn media_search_bundled(sp: search_params.Media, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("modality", sp.modality),
    #("subject", sp.subject),
    #("created", sp.created),
    #("encounter", sp.encounter),
    #("type", sp.type_),
    #("operator", sp.operator),
    #("view", sp.view),
    #("site", sp.site),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("device", sp.device),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedia, client)
}

pub fn media_search(
  sp: search_params.Media,
  client: FhirClient,
) -> Result(List(resources.Media), Err) {
  case media_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.media)
    Error(error) -> Error(error)
  }
}

pub fn medication_search_bundled(
  sp: search_params.Medication,
  client: FhirClient,
) {
  search_params.to_string([
    #("ingredient-code", sp.ingredient_code),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("ingredient", sp.ingredient),
    #("form", sp.form),
    #("lot-number", sp.lot_number),
    #("expiration-date", sp.expiration_date),
    #("manufacturer", sp.manufacturer),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedication, client)
}

pub fn medication_search(
  sp: search_params.Medication,
  client: FhirClient,
) -> Result(List(resources.Medication), Err) {
  case medication_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.medication)
    Error(error) -> Error(error)
  }
}

pub fn medicationadministration_search_bundled(
  sp: search_params.Medicationadministration,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("code", sp.code),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("medication", sp.medication),
    #("reason-given", sp.reason_given),
    #("patient", sp.patient),
    #("effective-time", sp.effective_time),
    #("context", sp.context),
    #("reason-not-given", sp.reason_not_given),
    #("device", sp.device),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationadministration, client)
}

pub fn medicationadministration_search(
  sp: search_params.Medicationadministration,
  client: FhirClient,
) -> Result(List(resources.Medicationadministration), Err) {
  case medicationadministration_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicationadministration,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicationdispense_search_bundled(
  sp: search_params.Medicationdispense,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("code", sp.code),
    #("receiver", sp.receiver),
    #("subject", sp.subject),
    #("destination", sp.destination),
    #("medication", sp.medication),
    #("responsibleparty", sp.responsibleparty),
    #("type", sp.type_),
    #("whenhandedover", sp.whenhandedover),
    #("whenprepared", sp.whenprepared),
    #("prescription", sp.prescription),
    #("patient", sp.patient),
    #("context", sp.context),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationdispense, client)
}

pub fn medicationdispense_search(
  sp: search_params.Medicationdispense,
  client: FhirClient,
) -> Result(List(resources.Medicationdispense), Err) {
  case medicationdispense_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationdispense)
    Error(error) -> Error(error)
  }
}

pub fn medicationknowledge_search_bundled(
  sp: search_params.Medicationknowledge,
  client: FhirClient,
) {
  search_params.to_string([
    #("code", sp.code),
    #("ingredient", sp.ingredient),
    #("doseform", sp.doseform),
    #("classification-type", sp.classification_type),
    #("monograph-type", sp.monograph_type),
    #("classification", sp.classification),
    #("manufacturer", sp.manufacturer),
    #("ingredient-code", sp.ingredient_code),
    #("source-cost", sp.source_cost),
    #("monograph", sp.monograph),
    #("monitoring-program-name", sp.monitoring_program_name),
    #("monitoring-program-type", sp.monitoring_program_type),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationknowledge, client)
}

pub fn medicationknowledge_search(
  sp: search_params.Medicationknowledge,
  client: FhirClient,
) -> Result(List(resources.Medicationknowledge), Err) {
  case medicationknowledge_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationknowledge)
    Error(error) -> Error(error)
  }
}

pub fn medicationrequest_search_bundled(
  sp: search_params.Medicationrequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("requester", sp.requester),
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("intended-dispenser", sp.intended_dispenser),
    #("authoredon", sp.authoredon),
    #("code", sp.code),
    #("subject", sp.subject),
    #("medication", sp.medication),
    #("encounter", sp.encounter),
    #("priority", sp.priority),
    #("intent", sp.intent),
    #("patient", sp.patient),
    #("intended-performer", sp.intended_performer),
    #("intended-performertype", sp.intended_performertype),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationrequest, client)
}

pub fn medicationrequest_search(
  sp: search_params.Medicationrequest,
  client: FhirClient,
) -> Result(List(resources.Medicationrequest), Err) {
  case medicationrequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationrequest)
    Error(error) -> Error(error)
  }
}

pub fn medicationstatement_search_bundled(
  sp: search_params.Medicationstatement,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("effective", sp.effective),
    #("code", sp.code),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("context", sp.context),
    #("medication", sp.medication),
    #("part-of", sp.part_of),
    #("source", sp.source),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicationstatement, client)
}

pub fn medicationstatement_search(
  sp: search_params.Medicationstatement,
  client: FhirClient,
) -> Result(List(resources.Medicationstatement), Err) {
  case medicationstatement_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.medicationstatement)
    Error(error) -> Error(error)
  }
}

pub fn medicinalproduct_search_bundled(
  sp: search_params.Medicinalproduct,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("name", sp.name),
    #("name-language", sp.name_language),
  ])
  |> search_any(resources.RtMedicinalproduct, client)
}

pub fn medicinalproduct_search(
  sp: search_params.Medicinalproduct,
  client: FhirClient,
) -> Result(List(resources.Medicinalproduct), Err) {
  case medicinalproduct_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.medicinalproduct)
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductauthorization_search_bundled(
  sp: search_params.Medicinalproductauthorization,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("country", sp.country),
    #("subject", sp.subject),
    #("holder", sp.holder),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMedicinalproductauthorization, client)
}

pub fn medicinalproductauthorization_search(
  sp: search_params.Medicinalproductauthorization,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductauthorization), Err) {
  case medicinalproductauthorization_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductauthorization,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductcontraindication_search_bundled(
  sp: search_params.Medicinalproductcontraindication,
  client: FhirClient,
) {
  search_params.to_string([
    #("subject", sp.subject),
  ])
  |> search_any(resources.RtMedicinalproductcontraindication, client)
}

pub fn medicinalproductcontraindication_search(
  sp: search_params.Medicinalproductcontraindication,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductcontraindication), Err) {
  case medicinalproductcontraindication_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductcontraindication,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductindication_search_bundled(
  sp: search_params.Medicinalproductindication,
  client: FhirClient,
) {
  search_params.to_string([
    #("subject", sp.subject),
  ])
  |> search_any(resources.RtMedicinalproductindication, client)
}

pub fn medicinalproductindication_search(
  sp: search_params.Medicinalproductindication,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductindication), Err) {
  case medicinalproductindication_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductindication,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductingredient_search_bundled(
  _sp: search_params.Medicinalproductingredient,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtMedicinalproductingredient, client)
}

pub fn medicinalproductingredient_search(
  sp: search_params.Medicinalproductingredient,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductingredient), Err) {
  case medicinalproductingredient_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductingredient,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductinteraction_search_bundled(
  sp: search_params.Medicinalproductinteraction,
  client: FhirClient,
) {
  search_params.to_string([
    #("subject", sp.subject),
  ])
  |> search_any(resources.RtMedicinalproductinteraction, client)
}

pub fn medicinalproductinteraction_search(
  sp: search_params.Medicinalproductinteraction,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductinteraction), Err) {
  case medicinalproductinteraction_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductinteraction,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductmanufactured_search_bundled(
  _sp: search_params.Medicinalproductmanufactured,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtMedicinalproductmanufactured, client)
}

pub fn medicinalproductmanufactured_search(
  sp: search_params.Medicinalproductmanufactured,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductmanufactured), Err) {
  case medicinalproductmanufactured_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductmanufactured,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductpackaged_search_bundled(
  sp: search_params.Medicinalproductpackaged,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("subject", sp.subject),
  ])
  |> search_any(resources.RtMedicinalproductpackaged, client)
}

pub fn medicinalproductpackaged_search(
  sp: search_params.Medicinalproductpackaged,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductpackaged), Err) {
  case medicinalproductpackaged_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductpackaged,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductpharmaceutical_search_bundled(
  sp: search_params.Medicinalproductpharmaceutical,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("route", sp.route),
    #("target-species", sp.target_species),
  ])
  |> search_any(resources.RtMedicinalproductpharmaceutical, client)
}

pub fn medicinalproductpharmaceutical_search(
  sp: search_params.Medicinalproductpharmaceutical,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductpharmaceutical), Err) {
  case medicinalproductpharmaceutical_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductpharmaceutical,
      )
    Error(error) -> Error(error)
  }
}

pub fn medicinalproductundesirableeffect_search_bundled(
  sp: search_params.Medicinalproductundesirableeffect,
  client: FhirClient,
) {
  search_params.to_string([
    #("subject", sp.subject),
  ])
  |> search_any(resources.RtMedicinalproductundesirableeffect, client)
}

pub fn medicinalproductundesirableeffect_search(
  sp: search_params.Medicinalproductundesirableeffect,
  client: FhirClient,
) -> Result(List(resources.Medicinalproductundesirableeffect), Err) {
  case medicinalproductundesirableeffect_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.medicinalproductundesirableeffect,
      )
    Error(error) -> Error(error)
  }
}

pub fn messagedefinition_search_bundled(
  sp: search_params.Messagedefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("parent", sp.parent),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("focus", sp.focus),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("event", sp.event),
    #("category", sp.category),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtMessagedefinition, client)
}

pub fn messagedefinition_search(
  sp: search_params.Messagedefinition,
  client: FhirClient,
) -> Result(List(resources.Messagedefinition), Err) {
  case messagedefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.messagedefinition)
    Error(error) -> Error(error)
  }
}

pub fn messageheader_search_bundled(
  sp: search_params.Messageheader,
  client: FhirClient,
) {
  search_params.to_string([
    #("code", sp.code),
    #("receiver", sp.receiver),
    #("author", sp.author),
    #("destination", sp.destination),
    #("focus", sp.focus),
    #("source", sp.source),
    #("target", sp.target),
    #("destination-uri", sp.destination_uri),
    #("source-uri", sp.source_uri),
    #("sender", sp.sender),
    #("responsible", sp.responsible),
    #("enterer", sp.enterer),
    #("response-id", sp.response_id),
    #("event", sp.event),
  ])
  |> search_any(resources.RtMessageheader, client)
}

pub fn messageheader_search(
  sp: search_params.Messageheader,
  client: FhirClient,
) -> Result(List(resources.Messageheader), Err) {
  case messageheader_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.messageheader)
    Error(error) -> Error(error)
  }
}

pub fn molecularsequence_search_bundled(
  sp: search_params.Molecularsequence,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("referenceseqid-variant-coordinate", sp.referenceseqid_variant_coordinate),
    #("chromosome", sp.chromosome),
    #("window-end", sp.window_end),
    #("type", sp.type_),
    #("window-start", sp.window_start),
    #("variant-end", sp.variant_end),
    #("chromosome-variant-coordinate", sp.chromosome_variant_coordinate),
    #("patient", sp.patient),
    #("variant-start", sp.variant_start),
    #("chromosome-window-coordinate", sp.chromosome_window_coordinate),
    #("referenceseqid-window-coordinate", sp.referenceseqid_window_coordinate),
    #("referenceseqid", sp.referenceseqid),
  ])
  |> search_any(resources.RtMolecularsequence, client)
}

pub fn molecularsequence_search(
  sp: search_params.Molecularsequence,
  client: FhirClient,
) -> Result(List(resources.Molecularsequence), Err) {
  case molecularsequence_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.molecularsequence)
    Error(error) -> Error(error)
  }
}

pub fn namingsystem_search_bundled(
  sp: search_params.Namingsystem,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("period", sp.period),
    #("context-type-value", sp.context_type_value),
    #("kind", sp.kind),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("type", sp.type_),
    #("id-type", sp.id_type),
    #("context-quantity", sp.context_quantity),
    #("responsible", sp.responsible),
    #("contact", sp.contact),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("telecom", sp.telecom),
    #("value", sp.value),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtNamingsystem, client)
}

pub fn namingsystem_search(
  sp: search_params.Namingsystem,
  client: FhirClient,
) -> Result(List(resources.Namingsystem), Err) {
  case namingsystem_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.namingsystem)
    Error(error) -> Error(error)
  }
}

pub fn nutritionorder_search_bundled(
  sp: search_params.Nutritionorder,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("datetime", sp.datetime),
    #("provider", sp.provider),
    #("patient", sp.patient),
    #("supplement", sp.supplement),
    #("formula", sp.formula),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("instantiates-uri", sp.instantiates_uri),
    #("encounter", sp.encounter),
    #("oraldiet", sp.oraldiet),
    #("status", sp.status),
    #("additive", sp.additive),
  ])
  |> search_any(resources.RtNutritionorder, client)
}

pub fn nutritionorder_search(
  sp: search_params.Nutritionorder,
  client: FhirClient,
) -> Result(List(resources.Nutritionorder), Err) {
  case nutritionorder_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.nutritionorder)
    Error(error) -> Error(error)
  }
}

pub fn observation_search_bundled(
  sp: search_params.Observation,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("combo-data-absent-reason", sp.combo_data_absent_reason),
    #("code", sp.code),
    #("combo-code-value-quantity", sp.combo_code_value_quantity),
    #("subject", sp.subject),
    #("component-data-absent-reason", sp.component_data_absent_reason),
    #("value-concept", sp.value_concept),
    #("value-date", sp.value_date),
    #("focus", sp.focus),
    #("derived-from", sp.derived_from),
    #("part-of", sp.part_of),
    #("has-member", sp.has_member),
    #("code-value-string", sp.code_value_string),
    #("component-code-value-quantity", sp.component_code_value_quantity),
    #("based-on", sp.based_on),
    #("code-value-date", sp.code_value_date),
    #("patient", sp.patient),
    #("specimen", sp.specimen),
    #("component-code", sp.component_code),
    #("code-value-quantity", sp.code_value_quantity),
    #("combo-code-value-concept", sp.combo_code_value_concept),
    #("value-string", sp.value_string),
    #("identifier", sp.identifier),
    #("performer", sp.performer),
    #("combo-code", sp.combo_code),
    #("method", sp.method),
    #("value-quantity", sp.value_quantity),
    #("component-value-quantity", sp.component_value_quantity),
    #("data-absent-reason", sp.data_absent_reason),
    #("combo-value-quantity", sp.combo_value_quantity),
    #("encounter", sp.encounter),
    #("code-value-concept", sp.code_value_concept),
    #("component-code-value-concept", sp.component_code_value_concept),
    #("component-value-concept", sp.component_value_concept),
    #("category", sp.category),
    #("device", sp.device),
    #("combo-value-concept", sp.combo_value_concept),
    #("status", sp.status),
  ])
  |> search_any(resources.RtObservation, client)
}

pub fn observation_search(
  sp: search_params.Observation,
  client: FhirClient,
) -> Result(List(resources.Observation), Err) {
  case observation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.observation)
    Error(error) -> Error(error)
  }
}

pub fn observationdefinition_search_bundled(
  _sp: search_params.Observationdefinition,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtObservationdefinition, client)
}

pub fn observationdefinition_search(
  sp: search_params.Observationdefinition,
  client: FhirClient,
) -> Result(List(resources.Observationdefinition), Err) {
  case observationdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.observationdefinition)
    Error(error) -> Error(error)
  }
}

pub fn operationdefinition_search_bundled(
  sp: search_params.Operationdefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("code", sp.code),
    #("instance", sp.instance),
    #("context-type-value", sp.context_type_value),
    #("kind", sp.kind),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("input-profile", sp.input_profile),
    #("output-profile", sp.output_profile),
    #("system", sp.system),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
    #("base", sp.base),
  ])
  |> search_any(resources.RtOperationdefinition, client)
}

pub fn operationdefinition_search(
  sp: search_params.Operationdefinition,
  client: FhirClient,
) -> Result(List(resources.Operationdefinition), Err) {
  case operationdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.operationdefinition)
    Error(error) -> Error(error)
  }
}

pub fn operationoutcome_search_bundled(
  _sp: search_params.Operationoutcome,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtOperationoutcome, client)
}

pub fn operationoutcome_search(
  sp: search_params.Operationoutcome,
  client: FhirClient,
) -> Result(List(resources.Operationoutcome), Err) {
  case operationoutcome_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.operationoutcome)
    Error(error) -> Error(error)
  }
}

pub fn organization_search_bundled(
  sp: search_params.Organization,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("partof", sp.partof),
    #("address", sp.address),
    #("address-state", sp.address_state),
    #("active", sp.active),
    #("type", sp.type_),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("endpoint", sp.endpoint),
    #("phonetic", sp.phonetic),
    #("name", sp.name),
    #("address-use", sp.address_use),
    #("address-city", sp.address_city),
  ])
  |> search_any(resources.RtOrganization, client)
}

pub fn organization_search(
  sp: search_params.Organization,
  client: FhirClient,
) -> Result(List(resources.Organization), Err) {
  case organization_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.organization)
    Error(error) -> Error(error)
  }
}

pub fn organizationaffiliation_search_bundled(
  sp: search_params.Organizationaffiliation,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("role", sp.role),
    #("active", sp.active),
    #("primary-organization", sp.primary_organization),
    #("network", sp.network),
    #("endpoint", sp.endpoint),
    #("phone", sp.phone),
    #("service", sp.service),
    #("participating-organization", sp.participating_organization),
    #("telecom", sp.telecom),
    #("location", sp.location),
    #("email", sp.email),
  ])
  |> search_any(resources.RtOrganizationaffiliation, client)
}

pub fn organizationaffiliation_search(
  sp: search_params.Organizationaffiliation,
  client: FhirClient,
) -> Result(List(resources.Organizationaffiliation), Err) {
  case organizationaffiliation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.organizationaffiliation,
      )
    Error(error) -> Error(error)
  }
}

pub fn patient_search_bundled(sp: search_params.Patient, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("given", sp.given),
    #("address", sp.address),
    #("birthdate", sp.birthdate),
    #("deceased", sp.deceased),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("general-practitioner", sp.general_practitioner),
    #("link", sp.link),
    #("active", sp.active),
    #("language", sp.language),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("death-date", sp.death_date),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("organization", sp.organization),
    #("name", sp.name),
    #("address-use", sp.address_use),
    #("telecom", sp.telecom),
    #("family", sp.family),
    #("address-city", sp.address_city),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPatient, client)
}

pub fn patient_search(
  sp: search_params.Patient,
  client: FhirClient,
) -> Result(List(resources.Patient), Err) {
  case patient_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.patient)
    Error(error) -> Error(error)
  }
}

pub fn paymentnotice_search_bundled(
  sp: search_params.Paymentnotice,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("provider", sp.provider),
    #("created", sp.created),
    #("response", sp.response),
    #("payment-status", sp.payment_status),
    #("status", sp.status),
  ])
  |> search_any(resources.RtPaymentnotice, client)
}

pub fn paymentnotice_search(
  sp: search_params.Paymentnotice,
  client: FhirClient,
) -> Result(List(resources.Paymentnotice), Err) {
  case paymentnotice_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.paymentnotice)
    Error(error) -> Error(error)
  }
}

pub fn paymentreconciliation_search_bundled(
  sp: search_params.Paymentreconciliation,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("request", sp.request),
    #("disposition", sp.disposition),
    #("created", sp.created),
    #("payment-issuer", sp.payment_issuer),
    #("outcome", sp.outcome),
    #("requestor", sp.requestor),
    #("status", sp.status),
  ])
  |> search_any(resources.RtPaymentreconciliation, client)
}

pub fn paymentreconciliation_search(
  sp: search_params.Paymentreconciliation,
  client: FhirClient,
) -> Result(List(resources.Paymentreconciliation), Err) {
  case paymentreconciliation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.paymentreconciliation)
    Error(error) -> Error(error)
  }
}

pub fn person_search_bundled(sp: search_params.Person, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("address", sp.address),
    #("birthdate", sp.birthdate),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("practitioner", sp.practitioner),
    #("link", sp.link),
    #("relatedperson", sp.relatedperson),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("patient", sp.patient),
    #("organization", sp.organization),
    #("name", sp.name),
    #("address-use", sp.address_use),
    #("telecom", sp.telecom),
    #("address-city", sp.address_city),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPerson, client)
}

pub fn person_search(
  sp: search_params.Person,
  client: FhirClient,
) -> Result(List(resources.Person), Err) {
  case person_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.person)
    Error(error) -> Error(error)
  }
}

pub fn plandefinition_search_bundled(
  sp: search_params.Plandefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("definition", sp.definition),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtPlandefinition, client)
}

pub fn plandefinition_search(
  sp: search_params.Plandefinition,
  client: FhirClient,
) -> Result(List(resources.Plandefinition), Err) {
  case plandefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.plandefinition)
    Error(error) -> Error(error)
  }
}

pub fn practitioner_search_bundled(
  sp: search_params.Practitioner,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("given", sp.given),
    #("address", sp.address),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("active", sp.active),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("name", sp.name),
    #("address-use", sp.address_use),
    #("telecom", sp.telecom),
    #("family", sp.family),
    #("address-city", sp.address_city),
    #("communication", sp.communication),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPractitioner, client)
}

pub fn practitioner_search(
  sp: search_params.Practitioner,
  client: FhirClient,
) -> Result(List(resources.Practitioner), Err) {
  case practitioner_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.practitioner)
    Error(error) -> Error(error)
  }
}

pub fn practitionerrole_search_bundled(
  sp: search_params.Practitionerrole,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("role", sp.role),
    #("practitioner", sp.practitioner),
    #("active", sp.active),
    #("endpoint", sp.endpoint),
    #("phone", sp.phone),
    #("service", sp.service),
    #("organization", sp.organization),
    #("telecom", sp.telecom),
    #("location", sp.location),
    #("email", sp.email),
  ])
  |> search_any(resources.RtPractitionerrole, client)
}

pub fn practitionerrole_search(
  sp: search_params.Practitionerrole,
  client: FhirClient,
) -> Result(List(resources.Practitionerrole), Err) {
  case practitionerrole_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.practitionerrole)
    Error(error) -> Error(error)
  }
}

pub fn procedure_search_bundled(sp: search_params.Procedure, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("reason-code", sp.reason_code),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("reason-reference", sp.reason_reference),
    #("location", sp.location),
    #("instantiates-uri", sp.instantiates_uri),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtProcedure, client)
}

pub fn procedure_search(
  sp: search_params.Procedure,
  client: FhirClient,
) -> Result(List(resources.Procedure), Err) {
  case procedure_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.procedure)
    Error(error) -> Error(error)
  }
}

pub fn provenance_search_bundled(
  sp: search_params.Provenance,
  client: FhirClient,
) {
  search_params.to_string([
    #("agent-type", sp.agent_type),
    #("agent", sp.agent),
    #("signature-type", sp.signature_type),
    #("patient", sp.patient),
    #("location", sp.location),
    #("recorded", sp.recorded),
    #("agent-role", sp.agent_role),
    #("when", sp.when),
    #("entity", sp.entity),
    #("target", sp.target),
  ])
  |> search_any(resources.RtProvenance, client)
}

pub fn provenance_search(
  sp: search_params.Provenance,
  client: FhirClient,
) -> Result(List(resources.Provenance), Err) {
  case provenance_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.provenance)
    Error(error) -> Error(error)
  }
}

pub fn questionnaire_search_bundled(
  sp: search_params.Questionnaire,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("subject-type", sp.subject_type),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("definition", sp.definition),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtQuestionnaire, client)
}

pub fn questionnaire_search(
  sp: search_params.Questionnaire,
  client: FhirClient,
) -> Result(List(resources.Questionnaire), Err) {
  case questionnaire_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.questionnaire)
    Error(error) -> Error(error)
  }
}

pub fn questionnaireresponse_search_bundled(
  sp: search_params.Questionnaireresponse,
  client: FhirClient,
) {
  search_params.to_string([
    #("authored", sp.authored),
    #("identifier", sp.identifier),
    #("questionnaire", sp.questionnaire),
    #("based-on", sp.based_on),
    #("subject", sp.subject),
    #("author", sp.author),
    #("patient", sp.patient),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("source", sp.source),
    #("status", sp.status),
  ])
  |> search_any(resources.RtQuestionnaireresponse, client)
}

pub fn questionnaireresponse_search(
  sp: search_params.Questionnaireresponse,
  client: FhirClient,
) -> Result(List(resources.Questionnaireresponse), Err) {
  case questionnaireresponse_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.questionnaireresponse)
    Error(error) -> Error(error)
  }
}

pub fn relatedperson_search_bundled(
  sp: search_params.Relatedperson,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("address", sp.address),
    #("birthdate", sp.birthdate),
    #("address-state", sp.address_state),
    #("gender", sp.gender),
    #("active", sp.active),
    #("address-postalcode", sp.address_postalcode),
    #("address-country", sp.address_country),
    #("phonetic", sp.phonetic),
    #("phone", sp.phone),
    #("patient", sp.patient),
    #("name", sp.name),
    #("address-use", sp.address_use),
    #("telecom", sp.telecom),
    #("address-city", sp.address_city),
    #("relationship", sp.relationship),
    #("email", sp.email),
  ])
  |> search_any(resources.RtRelatedperson, client)
}

pub fn relatedperson_search(
  sp: search_params.Relatedperson,
  client: FhirClient,
) -> Result(List(resources.Relatedperson), Err) {
  case relatedperson_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.relatedperson)
    Error(error) -> Error(error)
  }
}

pub fn requestgroup_search_bundled(
  sp: search_params.Requestgroup,
  client: FhirClient,
) {
  search_params.to_string([
    #("authored", sp.authored),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("subject", sp.subject),
    #("author", sp.author),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("encounter", sp.encounter),
    #("priority", sp.priority),
    #("intent", sp.intent),
    #("participant", sp.participant),
    #("group-identifier", sp.group_identifier),
    #("patient", sp.patient),
    #("instantiates-uri", sp.instantiates_uri),
    #("status", sp.status),
  ])
  |> search_any(resources.RtRequestgroup, client)
}

pub fn requestgroup_search(
  sp: search_params.Requestgroup,
  client: FhirClient,
) -> Result(List(resources.Requestgroup), Err) {
  case requestgroup_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.requestgroup)
    Error(error) -> Error(error)
  }
}

pub fn researchdefinition_search_bundled(
  sp: search_params.Researchdefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtResearchdefinition, client)
}

pub fn researchdefinition_search(
  sp: search_params.Researchdefinition,
  client: FhirClient,
) -> Result(List(resources.Researchdefinition), Err) {
  case researchdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.researchdefinition)
    Error(error) -> Error(error)
  }
}

pub fn researchelementdefinition_search_bundled(
  sp: search_params.Researchelementdefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("successor", sp.successor),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("predecessor", sp.predecessor),
    #("title", sp.title),
    #("composed-of", sp.composed_of),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("depends-on", sp.depends_on),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("topic", sp.topic),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtResearchelementdefinition, client)
}

pub fn researchelementdefinition_search(
  sp: search_params.Researchelementdefinition,
  client: FhirClient,
) -> Result(List(resources.Researchelementdefinition), Err) {
  case researchelementdefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.researchelementdefinition,
      )
    Error(error) -> Error(error)
  }
}

pub fn researchstudy_search_bundled(
  sp: search_params.Researchstudy,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("partof", sp.partof),
    #("sponsor", sp.sponsor),
    #("focus", sp.focus),
    #("principalinvestigator", sp.principalinvestigator),
    #("title", sp.title),
    #("protocol", sp.protocol),
    #("site", sp.site),
    #("location", sp.location),
    #("category", sp.category),
    #("keyword", sp.keyword),
    #("status", sp.status),
  ])
  |> search_any(resources.RtResearchstudy, client)
}

pub fn researchstudy_search(
  sp: search_params.Researchstudy,
  client: FhirClient,
) -> Result(List(resources.Researchstudy), Err) {
  case researchstudy_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.researchstudy)
    Error(error) -> Error(error)
  }
}

pub fn researchsubject_search_bundled(
  sp: search_params.Researchsubject,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("study", sp.study),
    #("individual", sp.individual),
    #("patient", sp.patient),
    #("status", sp.status),
  ])
  |> search_any(resources.RtResearchsubject, client)
}

pub fn researchsubject_search(
  sp: search_params.Researchsubject,
  client: FhirClient,
) -> Result(List(resources.Researchsubject), Err) {
  case researchsubject_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.researchsubject)
    Error(error) -> Error(error)
  }
}

pub fn riskassessment_search_bundled(
  sp: search_params.Riskassessment,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("condition", sp.condition),
    #("performer", sp.performer),
    #("method", sp.method),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("probability", sp.probability),
    #("risk", sp.risk),
    #("encounter", sp.encounter),
  ])
  |> search_any(resources.RtRiskassessment, client)
}

pub fn riskassessment_search(
  sp: search_params.Riskassessment,
  client: FhirClient,
) -> Result(List(resources.Riskassessment), Err) {
  case riskassessment_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.riskassessment)
    Error(error) -> Error(error)
  }
}

pub fn riskevidencesynthesis_search_bundled(
  sp: search_params.Riskevidencesynthesis,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("effective", sp.effective),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtRiskevidencesynthesis, client)
}

pub fn riskevidencesynthesis_search(
  sp: search_params.Riskevidencesynthesis,
  client: FhirClient,
) -> Result(List(resources.Riskevidencesynthesis), Err) {
  case riskevidencesynthesis_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.riskevidencesynthesis)
    Error(error) -> Error(error)
  }
}

pub fn schedule_search_bundled(sp: search_params.Schedule, client: FhirClient) {
  search_params.to_string([
    #("actor", sp.actor),
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("service-category", sp.service_category),
    #("service-type", sp.service_type),
    #("active", sp.active),
  ])
  |> search_any(resources.RtSchedule, client)
}

pub fn schedule_search(
  sp: search_params.Schedule,
  client: FhirClient,
) -> Result(List(resources.Schedule), Err) {
  case schedule_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.schedule)
    Error(error) -> Error(error)
  }
}

pub fn searchparameter_search_bundled(
  sp: search_params.Searchparameter,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("derived-from", sp.derived_from),
    #("context-type", sp.context_type),
    #("type", sp.type_),
    #("version", sp.version),
    #("url", sp.url),
    #("target", sp.target),
    #("context-quantity", sp.context_quantity),
    #("component", sp.component),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
    #("base", sp.base),
  ])
  |> search_any(resources.RtSearchparameter, client)
}

pub fn searchparameter_search(
  sp: search_params.Searchparameter,
  client: FhirClient,
) -> Result(List(resources.Searchparameter), Err) {
  case searchparameter_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.searchparameter)
    Error(error) -> Error(error)
  }
}

pub fn servicerequest_search_bundled(
  sp: search_params.Servicerequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("authored", sp.authored),
    #("requester", sp.requester),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("performer", sp.performer),
    #("requisition", sp.requisition),
    #("replaces", sp.replaces),
    #("subject", sp.subject),
    #("instantiates-canonical", sp.instantiates_canonical),
    #("encounter", sp.encounter),
    #("occurrence", sp.occurrence),
    #("priority", sp.priority),
    #("intent", sp.intent),
    #("performer-type", sp.performer_type),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("specimen", sp.specimen),
    #("instantiates-uri", sp.instantiates_uri),
    #("body-site", sp.body_site),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtServicerequest, client)
}

pub fn servicerequest_search(
  sp: search_params.Servicerequest,
  client: FhirClient,
) -> Result(List(resources.Servicerequest), Err) {
  case servicerequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.servicerequest)
    Error(error) -> Error(error)
  }
}

pub fn slot_search_bundled(sp: search_params.Slot, client: FhirClient) {
  search_params.to_string([
    #("schedule", sp.schedule),
    #("identifier", sp.identifier),
    #("specialty", sp.specialty),
    #("service-category", sp.service_category),
    #("appointment-type", sp.appointment_type),
    #("service-type", sp.service_type),
    #("start", sp.start),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSlot, client)
}

pub fn slot_search(
  sp: search_params.Slot,
  client: FhirClient,
) -> Result(List(resources.Slot), Err) {
  case slot_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.slot)
    Error(error) -> Error(error)
  }
}

pub fn specimen_search_bundled(sp: search_params.Specimen, client: FhirClient) {
  search_params.to_string([
    #("container", sp.container),
    #("identifier", sp.identifier),
    #("parent", sp.parent),
    #("container-id", sp.container_id),
    #("bodysite", sp.bodysite),
    #("subject", sp.subject),
    #("patient", sp.patient),
    #("collected", sp.collected),
    #("accession", sp.accession),
    #("type", sp.type_),
    #("collector", sp.collector),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSpecimen, client)
}

pub fn specimen_search(
  sp: search_params.Specimen,
  client: FhirClient,
) -> Result(List(resources.Specimen), Err) {
  case specimen_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.specimen)
    Error(error) -> Error(error)
  }
}

pub fn specimendefinition_search_bundled(
  sp: search_params.Specimendefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("container", sp.container),
    #("identifier", sp.identifier),
    #("type", sp.type_),
  ])
  |> search_any(resources.RtSpecimendefinition, client)
}

pub fn specimendefinition_search(
  sp: search_params.Specimendefinition,
  client: FhirClient,
) -> Result(List(resources.Specimendefinition), Err) {
  case specimendefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.specimendefinition)
    Error(error) -> Error(error)
  }
}

pub fn structuredefinition_search_bundled(
  sp: search_params.Structuredefinition,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("experimental", sp.experimental),
    #("title", sp.title),
    #("type", sp.type_),
    #("context-quantity", sp.context_quantity),
    #("path", sp.path),
    #("context", sp.context),
    #("base-path", sp.base_path),
    #("keyword", sp.keyword),
    #("context-type-quantity", sp.context_type_quantity),
    #("identifier", sp.identifier),
    #("valueset", sp.valueset),
    #("kind", sp.kind),
    #("abstract", sp.abstract),
    #("version", sp.version),
    #("url", sp.url),
    #("ext-context", sp.ext_context),
    #("name", sp.name),
    #("publisher", sp.publisher),
    #("derivation", sp.derivation),
    #("status", sp.status),
    #("base", sp.base),
  ])
  |> search_any(resources.RtStructuredefinition, client)
}

pub fn structuredefinition_search(
  sp: search_params.Structuredefinition,
  client: FhirClient,
) -> Result(List(resources.Structuredefinition), Err) {
  case structuredefinition_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.structuredefinition)
    Error(error) -> Error(error)
  }
}

pub fn structuremap_search_bundled(
  sp: search_params.Structuremap,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtStructuremap, client)
}

pub fn structuremap_search(
  sp: search_params.Structuremap,
  client: FhirClient,
) -> Result(List(resources.Structuremap), Err) {
  case structuremap_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.structuremap)
    Error(error) -> Error(error)
  }
}

pub fn subscription_search_bundled(
  sp: search_params.Subscription,
  client: FhirClient,
) {
  search_params.to_string([
    #("payload", sp.payload),
    #("criteria", sp.criteria),
    #("contact", sp.contact),
    #("type", sp.type_),
    #("url", sp.url),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSubscription, client)
}

pub fn subscription_search(
  sp: search_params.Subscription,
  client: FhirClient,
) -> Result(List(resources.Subscription), Err) {
  case subscription_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.subscription)
    Error(error) -> Error(error)
  }
}

pub fn substance_search_bundled(sp: search_params.Substance, client: FhirClient) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("container-identifier", sp.container_identifier),
    #("code", sp.code),
    #("quantity", sp.quantity),
    #("substance-reference", sp.substance_reference),
    #("expiry", sp.expiry),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSubstance, client)
}

pub fn substance_search(
  sp: search_params.Substance,
  client: FhirClient,
) -> Result(List(resources.Substance), Err) {
  case substance_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.substance)
    Error(error) -> Error(error)
  }
}

pub fn substancenucleicacid_search_bundled(
  _sp: search_params.Substancenucleicacid,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtSubstancenucleicacid, client)
}

pub fn substancenucleicacid_search(
  sp: search_params.Substancenucleicacid,
  client: FhirClient,
) -> Result(List(resources.Substancenucleicacid), Err) {
  case substancenucleicacid_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.substancenucleicacid)
    Error(error) -> Error(error)
  }
}

pub fn substancepolymer_search_bundled(
  _sp: search_params.Substancepolymer,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtSubstancepolymer, client)
}

pub fn substancepolymer_search(
  sp: search_params.Substancepolymer,
  client: FhirClient,
) -> Result(List(resources.Substancepolymer), Err) {
  case substancepolymer_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.substancepolymer)
    Error(error) -> Error(error)
  }
}

pub fn substanceprotein_search_bundled(
  _sp: search_params.Substanceprotein,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtSubstanceprotein, client)
}

pub fn substanceprotein_search(
  sp: search_params.Substanceprotein,
  client: FhirClient,
) -> Result(List(resources.Substanceprotein), Err) {
  case substanceprotein_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.substanceprotein)
    Error(error) -> Error(error)
  }
}

pub fn substancereferenceinformation_search_bundled(
  _sp: search_params.Substancereferenceinformation,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtSubstancereferenceinformation, client)
}

pub fn substancereferenceinformation_search(
  sp: search_params.Substancereferenceinformation,
  client: FhirClient,
) -> Result(List(resources.Substancereferenceinformation), Err) {
  case substancereferenceinformation_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.substancereferenceinformation,
      )
    Error(error) -> Error(error)
  }
}

pub fn substancesourcematerial_search_bundled(
  _sp: search_params.Substancesourcematerial,
  client: FhirClient,
) {
  search_params.to_string([])
  |> search_any(resources.RtSubstancesourcematerial, client)
}

pub fn substancesourcematerial_search(
  sp: search_params.Substancesourcematerial,
  client: FhirClient,
) -> Result(List(resources.Substancesourcematerial), Err) {
  case substancesourcematerial_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.substancesourcematerial,
      )
    Error(error) -> Error(error)
  }
}

pub fn substancespecification_search_bundled(
  sp: search_params.Substancespecification,
  client: FhirClient,
) {
  search_params.to_string([
    #("code", sp.code),
  ])
  |> search_any(resources.RtSubstancespecification, client)
}

pub fn substancespecification_search(
  sp: search_params.Substancespecification,
  client: FhirClient,
) -> Result(List(resources.Substancespecification), Err) {
  case substancespecification_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.substancespecification)
    Error(error) -> Error(error)
  }
}

pub fn supplydelivery_search_bundled(
  sp: search_params.Supplydelivery,
  client: FhirClient,
) {
  search_params.to_string([
    #("identifier", sp.identifier),
    #("receiver", sp.receiver),
    #("patient", sp.patient),
    #("supplier", sp.supplier),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSupplydelivery, client)
}

pub fn supplydelivery_search(
  sp: search_params.Supplydelivery,
  client: FhirClient,
) -> Result(List(resources.Supplydelivery), Err) {
  case supplydelivery_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.supplydelivery)
    Error(error) -> Error(error)
  }
}

pub fn supplyrequest_search_bundled(
  sp: search_params.Supplyrequest,
  client: FhirClient,
) {
  search_params.to_string([
    #("requester", sp.requester),
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("subject", sp.subject),
    #("supplier", sp.supplier),
    #("category", sp.category),
    #("status", sp.status),
  ])
  |> search_any(resources.RtSupplyrequest, client)
}

pub fn supplyrequest_search(
  sp: search_params.Supplyrequest,
  client: FhirClient,
) -> Result(List(resources.Supplyrequest), Err) {
  case supplyrequest_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.supplyrequest)
    Error(error) -> Error(error)
  }
}

pub fn task_search_bundled(sp: search_params.Task, client: FhirClient) {
  search_params.to_string([
    #("owner", sp.owner),
    #("requester", sp.requester),
    #("identifier", sp.identifier),
    #("business-status", sp.business_status),
    #("period", sp.period),
    #("code", sp.code),
    #("performer", sp.performer),
    #("subject", sp.subject),
    #("focus", sp.focus),
    #("part-of", sp.part_of),
    #("encounter", sp.encounter),
    #("priority", sp.priority),
    #("authored-on", sp.authored_on),
    #("intent", sp.intent),
    #("group-identifier", sp.group_identifier),
    #("based-on", sp.based_on),
    #("patient", sp.patient),
    #("modified", sp.modified),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTask, client)
}

pub fn task_search(
  sp: search_params.Task,
  client: FhirClient,
) -> Result(List(resources.Task), Err) {
  case task_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.task)
    Error(error) -> Error(error)
  }
}

pub fn terminologycapabilities_search_bundled(
  sp: search_params.Terminologycapabilities,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTerminologycapabilities, client)
}

pub fn terminologycapabilities_search(
  sp: search_params.Terminologycapabilities,
  client: FhirClient,
) -> Result(List(resources.Terminologycapabilities), Err) {
  case terminologycapabilities_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok(
        { bundle |> sansio.bundle_to_groupedresources }.terminologycapabilities,
      )
    Error(error) -> Error(error)
  }
}

pub fn testreport_search_bundled(
  sp: search_params.Testreport,
  client: FhirClient,
) {
  search_params.to_string([
    #("result", sp.result),
    #("identifier", sp.identifier),
    #("tester", sp.tester),
    #("testscript", sp.testscript),
    #("issued", sp.issued),
    #("participant", sp.participant),
  ])
  |> search_any(resources.RtTestreport, client)
}

pub fn testreport_search(
  sp: search_params.Testreport,
  client: FhirClient,
) -> Result(List(resources.Testreport), Err) {
  case testreport_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.testreport)
    Error(error) -> Error(error)
  }
}

pub fn testscript_search_bundled(
  sp: search_params.Testscript,
  client: FhirClient,
) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("testscript-capability", sp.testscript_capability),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtTestscript, client)
}

pub fn testscript_search(
  sp: search_params.Testscript,
  client: FhirClient,
) -> Result(List(resources.Testscript), Err) {
  case testscript_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.testscript)
    Error(error) -> Error(error)
  }
}

pub fn valueset_search_bundled(sp: search_params.Valueset, client: FhirClient) {
  search_params.to_string([
    #("date", sp.date),
    #("identifier", sp.identifier),
    #("code", sp.code),
    #("context-type-value", sp.context_type_value),
    #("jurisdiction", sp.jurisdiction),
    #("description", sp.description),
    #("context-type", sp.context_type),
    #("title", sp.title),
    #("version", sp.version),
    #("url", sp.url),
    #("expansion", sp.expansion),
    #("reference", sp.reference),
    #("context-quantity", sp.context_quantity),
    #("name", sp.name),
    #("context", sp.context),
    #("publisher", sp.publisher),
    #("context-type-quantity", sp.context_type_quantity),
    #("status", sp.status),
  ])
  |> search_any(resources.RtValueset, client)
}

pub fn valueset_search(
  sp: search_params.Valueset,
  client: FhirClient,
) -> Result(List(resources.Valueset), Err) {
  case valueset_search_bundled(sp, client) {
    Ok(bundle) -> Ok({ bundle |> sansio.bundle_to_groupedresources }.valueset)
    Error(error) -> Error(error)
  }
}

pub fn verificationresult_search_bundled(
  sp: search_params.Verificationresult,
  client: FhirClient,
) {
  search_params.to_string([
    #("target", sp.target),
  ])
  |> search_any(resources.RtVerificationresult, client)
}

pub fn verificationresult_search(
  sp: search_params.Verificationresult,
  client: FhirClient,
) -> Result(List(resources.Verificationresult), Err) {
  case verificationresult_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.verificationresult)
    Error(error) -> Error(error)
  }
}

pub fn visionprescription_search_bundled(
  sp: search_params.Visionprescription,
  client: FhirClient,
) {
  search_params.to_string([
    #("prescriber", sp.prescriber),
    #("identifier", sp.identifier),
    #("patient", sp.patient),
    #("datewritten", sp.datewritten),
    #("encounter", sp.encounter),
    #("status", sp.status),
  ])
  |> search_any(resources.RtVisionprescription, client)
}

pub fn visionprescription_search(
  sp: search_params.Visionprescription,
  client: FhirClient,
) -> Result(List(resources.Visionprescription), Err) {
  case visionprescription_search_bundled(sp, client) {
    Ok(bundle) ->
      Ok({ bundle |> sansio.bundle_to_groupedresources }.visionprescription)
    Error(error) -> Error(error)
  }
}
