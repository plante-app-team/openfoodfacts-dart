import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'package:openfoodfacts/openfoodfacts.dart';
import 'package:openfoodfacts/utils/UriReader.dart';
import 'package:path/path.dart';

import 'OpenFoodAPIConfiguration.dart';
import 'QueryType.dart';

abstract class HttpInterceptor {
  Future<http.Request>? interceptGet(Uri uri);
  Future<http.Response>? fullyInterceptGet(Uri uri);
  Future<http.Request>? interceptPost(Uri uri);
  Future<http.MultipartRequest>? interceptMultipart(String method, Uri uri);
}

/// General functions for sending http requests (post, get, multipart, ...)
class HttpHelper {
  /// Gets the instance
  static HttpHelper get instance => _instance ??= HttpHelper.internal();
  static HttpHelper? _instance;
  @visibleForTesting
  static set instance(HttpHelper value) => _instance = value;

  static HttpInterceptor? interceptor;

  factory HttpHelper() => instance;

  @protected

  /// A protected constructor to allow subclasses to create themselves.
  HttpHelper.internal();

  static const String USER_AGENT = 'Dart API';
  static const String FROM = 'anonymous';

  /// Adds user agent data to parameters, for statistics purpose
  static Map<String, String>? addUserAgentParameters(
    Map<String, String>? map,
  ) {
    if (OpenFoodAPIConfiguration.userAgent?.name != null) {
      map ??= <String, String>{};
      map['app_name'] = OpenFoodAPIConfiguration.userAgent!.name!;
    }
    if (OpenFoodAPIConfiguration.userAgent?.version != null) {
      map ??= <String, String>{};
      map['app_version'] = OpenFoodAPIConfiguration.userAgent!.version!;
    }
    if (OpenFoodAPIConfiguration.uuid != null) {
      map ??= <String, String>{};
      map['app_uuid'] = OpenFoodAPIConfiguration.uuid!;
    }
    return map;
  }

  /// Send a http get request to the specified uri.
  /// The data of the request (if any) has to be provided as parameter within the uri.
  /// The result of the request will be returned as string.
  /// By default the query will hit the PROD DB
  Future<http.Response> doGetRequest(
    Uri uri, {
    User? user,
    QueryType? queryType,
  }) async {
    final fullInterception = await interceptor?.fullyInterceptGet(uri);
    if (fullInterception != null) {
      return fullInterception;
    }

    var request = await interceptor?.interceptGet(uri);
    request ??= http.Request('GET', uri);
    request.headers.addAll(_buildHeaders(
        user: user,
        isTestModeActive:
            OpenFoodAPIConfiguration.getQueryType(queryType) == QueryType.PROD
                ? false
                : true));
    return http.Response.fromStream(await request.send());

    // http.Response response = await http.get(
    //   uri,
    //   headers: _buildHeaders(
    //     user: user,
    //     isTestModeActive:
    //         OpenFoodAPIConfiguration.getQueryType(queryType) == QueryType.PROD
    //             ? false
    //             : true,
    //   ),
    // );

    // return response;
  }

  /// Send a http post request to the specified uri.
  /// The data / body of the request has to be provided as map. (key, value)
  /// The result of the request will be returned as string.
  Future<http.Response> doPostRequest(
    Uri uri,
    Map<String, String> body,
    User? user, {
    QueryType? queryType,
  }) async {
    var request = await interceptor?.interceptPost(uri);
    request ??= http.Request('POST', uri);
    request.headers.addAll(_buildHeaders(
        user: user,
        isTestModeActive:
            OpenFoodAPIConfiguration.getQueryType(queryType) == QueryType.PROD
                ? false
                : true));
    request.bodyFields = body.map((key, value) => MapEntry(key, value));
    if (user != null) {
      request.bodyFields.addAll(user.toData());
    }
    request.bodyFields = addUserAgentParameters(request.bodyFields) ?? {};
    return http.Response.fromStream(await request.send());

    // if (user != null) {
    //   body.addAll(user.toData());
    // }
    // http.Response response = await http.post(
    //   uri,
    //   headers: _buildHeaders(
    //       user: user,
    //       isTestModeActive:
    //           OpenFoodAPIConfiguration.getQueryType(queryType) == QueryType.PROD
    //               ? false
    //               : true),
    //   body: addUserAgentParameters(body),
    // );
    // return response;
  }

  /// Send a multipart post request to the specified uri.
  /// The data / body of the request has to be provided as map. (key, value)
  /// The files to send have to be provided as map containing the source file uri.
  /// As result a json object of the "type" Status is expected.
  Future<Status> doMultipartRequest(
    Uri uri,
    Map<String, String> body, {
    Map<String, Uri>? files,
    User? user,
    QueryType? queryType,
  }) async {
    var request = await interceptor?.interceptMultipart('POST', uri);
    request ??= http.MultipartRequest('POST', uri);

    request.headers.addAll(
      _buildHeaders(
        user: user,
        isTestModeActive:
            OpenFoodAPIConfiguration.getQueryType(queryType) == QueryType.PROD
                ? false
                : true,
      ) as Map<String, String>,
    );

    request.headers.addAll({'Content-Type': 'multipart/form-data'});
    request.fields.addAll(addUserAgentParameters(body)!);
    if (user != null) {
      request.fields.addAll(user.toData());
    }

    // add all file entries to the request
    if (files != null) {
      for (MapEntry<String, Uri> entry in files.entries) {
        List<int> fileBytes =
            await UriReader.instance!.readAsBytes(entry.value);
        var multipartFile = http.MultipartFile.fromBytes(entry.key, fileBytes,
            filename: basename(entry.value.toString()));
        request.files.add(multipartFile);
      }
    }

    // get the response status
    Status status = await request.send().then((response) {
      if (response.statusCode == 200) {
        return response.stream.first.then((responseBody) {
          try {
            return Status.fromJson(json.decode(utf8.decode(responseBody)));
          } catch (e) {
            //When the server returns html instead of json
            return Status(status: 200, body: utf8.decode(responseBody));
          }
        });
      } else {
        return Status(
            status: response.statusCode, error: response.reasonPhrase);
      }
    });
    return status;
  }

  /// build the request headers
  /// By default isTestMode is false
  Map<String, String> _buildHeaders({
    User? user,
    bool isTestModeActive = false,
  }) {
    Map<String, String> headers = {};

    headers.addAll({
      'Accept': 'application/json',
      'UserAgent':
          OpenFoodAPIConfiguration.userAgent?.toValueString() ?? USER_AGENT,
      'From': OpenFoodAPIConfiguration.getUser(user)?.toValueString() ?? FROM,
    });

    if (isTestModeActive) {
      var token = 'Basic ' + base64Encode(utf8.encode('off:off'));
      headers.addAll({'authorization': token});
    }
    return headers;
  }
}
