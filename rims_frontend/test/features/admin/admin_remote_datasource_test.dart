import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/admin/data/datasources/admin_remote_datasource.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_product.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_role.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_warehouse.dart';
import 'package:rims_frontend/features/admin/domain/entities/admin_user.dart';

void main() {
  test(
    'updateProduct sends an explicit empty imageUrl when clearing image',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"id":10,"code":"SKU-WA-550","name":"矿泉水","unit":"瓶","category":"","spec":"","barcode":"","retailPrice":3.5,"costPrice":1.2,"imageUrl":"","status":1}}',
      );
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(
          dio: Dio()..httpClientAdapter = adapter,
          enableLogging: false,
        ),
      );

      await dataSource.updateProduct(
        const UpdateAdminProductRequest(
          id: 10,
          code: 'SKU-WA-550',
          name: '矿泉水',
          unit: '瓶',
          imageUrl: '',
        ),
      );

      expect(
        (jsonDecode(adapter.lastBody!) as Map<String, dynamic>)['imageUrl'],
        '',
      );
    },
  );

  test('listUsers loads backend users endpoint with keyword and page', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":2,"username":"alice","realName":"张三","phone":"13800000000","email":"a@b.com","roleId":2,"roleCode":"user","roleName":"普通用户","status":1}],"total":45,"page":2,"pageSize":20}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listUsers(keyword: 'alice', page: 2);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastPath, '/users');
    expect(adapter.lastQuery, {'keyword': 'alice', 'page': 2, 'pageSize': 20});
    result.when(
      success: (page) {
        expect(page.items.single.id, 2);
        expect(page.items.single.username, 'alice');
        expect(page.items.single.roleName, '普通用户');
        expect(page.total, 45);
        expect(page.page, 2);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'admin list endpoints reject success envelope without list payload',
    () async {
      await _expectMissingListPayloadFailure(
        request: (dataSource) => dataSource.listUsers(),
        expectedMessage: 'Paged API data.list must be a JSON list.',
      );
      await _expectMissingListPayloadFailure(
        request: (dataSource) => dataSource.listProducts(),
        expectedMessage: 'Paged API data.list must be a JSON list.',
      );
      await _expectMissingListPayloadFailure(
        request: (dataSource) => dataSource.listWarehouses(),
        expectedMessage: 'Paged API data.list must be a JSON list.',
      );
      await _expectMissingListPayloadFailure(
        request: (dataSource) => dataSource.listWarehouseUsers(1),
        expectedMessage: 'Paged API data.list must be a JSON list.',
      );
      await _expectMissingListPayloadFailure(
        request: (dataSource) => dataSource.listRoles(),
        expectedMessage: 'Invalid roles response',
      );
      await _expectMissingListPayloadFailure(
        request: (dataSource) => dataSource.listPermissions(),
        expectedMessage: 'Invalid permissions response',
      );
    },
  );

  test(
    'admin list endpoints reject success envelope with non-object list item',
    () async {
      await _expectMalformedListItemFailure(
        request: (dataSource) => dataSource.listUsers(),
        expectedMessage: 'Every paged API list item must be a JSON object.',
      );
      await _expectMalformedListItemFailure(
        request: (dataSource) => dataSource.listProducts(),
        expectedMessage: 'Every paged API list item must be a JSON object.',
      );
      await _expectMalformedListItemFailure(
        request: (dataSource) => dataSource.listWarehouses(),
        expectedMessage: 'Every paged API list item must be a JSON object.',
      );
      await _expectMalformedListItemFailure(
        request: (dataSource) => dataSource.listWarehouseUsers(1),
        expectedMessage: 'Every paged API list item must be a JSON object.',
      );
      await _expectMalformedListItemFailure(
        request: (dataSource) => dataSource.listRoles(),
        expectedMessage: 'Invalid roles response',
      );
      await _expectMalformedListItemFailure(
        request: (dataSource) => dataSource.listPermissions(),
        expectedMessage: 'Invalid permissions response',
      );
    },
  );

  test('createUser posts backend user payload', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":3,"username":"bob","realName":"李四","phone":"","email":"","roleId":2,"roleCode":"user","roleName":"普通用户","status":1}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createUser(
      const CreateAdminUserRequest(
        username: 'bob',
        password: 'Pwd@12345',
        realName: '李四',
        roleId: 2,
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastPath, '/users');
    expect(jsonDecode(adapter.lastBody!), {
      'username': 'bob',
      'password': 'Pwd@12345',
      'realName': '李四',
      'roleId': 2,
    });
    result.when(
      success: (user) {
        expect(user.id, 3);
        expect(user.username, 'bob');
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('createUser rejects success envelope without user payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createUser(
      const CreateAdminUserRequest(
        username: 'bob',
        password: 'Pwd@12345',
        roleId: 2,
      ),
    );

    expect(result.isFailure, isTrue);
    result.when(
      success: (_) => fail('createUser should fail without backend user data'),
      failure: (failure) => expect(failure.message, 'Invalid user response'),
    );
  });

  test('createUser rejects success envelope with empty user object', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":{}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createUser(
      const CreateAdminUserRequest(
        username: 'bob',
        password: 'Pwd@12345',
        roleId: 2,
      ),
    );

    expect(result.isFailure, isTrue);
    result.when(
      success: (_) => fail('createUser should fail with an empty user object'),
      failure: (failure) => expect(failure.message, 'Invalid user response'),
    );
  });

  test('changeOwnPassword sends current user password payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.changeOwnPassword(
      const ChangeOwnPasswordRequest(
        oldPassword: 'old-secret',
        newPassword: 'new-secret',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/users/me/password');
    expect(jsonDecode(adapter.lastBody!), {
      'oldPassword': 'old-secret',
      'newPassword': 'new-secret',
    });
  });

  test('resetUserPassword sends admin reset password payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.resetUserPassword(
      const ResetUserPasswordRequest(userId: 2, newPassword: 'new-secret'),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/users/2/password');
    expect(jsonDecode(adapter.lastBody!), {'newPassword': 'new-secret'});
  });

  test('updateUser sends backend user update payload', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":2,"username":"alice","realName":"新名","phone":"13900000000","email":"new@b.com","roleId":3,"roleCode":"manager","roleName":"主管","status":0}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.updateUser(
      const UpdateAdminUserRequest(
        id: 2,
        realName: '新名',
        phone: '13900000000',
        email: 'new@b.com',
        roleId: 3,
        status: 0,
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/users/2');
    expect(jsonDecode(adapter.lastBody!), {
      'realName': '新名',
      'phone': '13900000000',
      'email': 'new@b.com',
      'roleId': 3,
      'status': 0,
    });
    result.when(
      success: (user) {
        expect(user.id, 2);
        expect(user.realName, '新名');
        expect(user.status, 0);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('updateUser rejects success envelope with empty user object', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":{}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.updateUser(
      const UpdateAdminUserRequest(id: 2, realName: '新名'),
    );

    expect(result.isFailure, isTrue);
    result.when(
      success: (_) => fail('updateUser should fail with an empty user object'),
      failure: (failure) => expect(failure.message, 'Invalid user response'),
    );
  });

  test('deleteUser sends backend user delete request', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.deleteUser(2);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'DELETE');
    expect(adapter.lastPath, '/users/2');
  });

  test(
    'listProducts loads backend products endpoint with keyword and page',
    () async {
      final adapter = _CapturingAdapter(
        body:
            '{"code":0,"message":"ok","data":{"list":[{"id":10,"code":"SKU-WA-550","name":"矿泉水 550ml","unit":"瓶","category":"饮料","spec":"550ml","barcode":"6901234567890","retailPrice":3.5,"costPrice":1.2,"imageUrl":"","status":1}],"total":45,"page":2,"pageSize":20}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.listProducts(keyword: '矿泉水', page: 2);

      expect(result.isSuccess, isTrue);
      expect(adapter.lastMethod, 'GET');
      expect(adapter.lastPath, '/products');
      expect(adapter.lastQuery, {'keyword': '矿泉水', 'page': 2, 'pageSize': 20});
      result.when(
        success: (page) {
          expect(page.items.single.id, 10);
          expect(page.items.single.code, 'SKU-WA-550');
          expect(page.items.single.name, '矿泉水 550ml');
          expect(page.items.single.costPrice, 1.2);
          expect(page.total, 45);
        },
        failure: (failure) => fail(failure.message),
      );
    },
  );

  test('createProduct posts backend product payload', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":11,"code":"SKU-TI","name":"纸巾","unit":"包","category":"日用品","spec":"","barcode":"","retailPrice":12.5,"costPrice":6.0,"imageUrl":"","status":1}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createProduct(
      const CreateAdminProductRequest(
        code: 'SKU-TI',
        name: '纸巾',
        unit: '包',
        category: '日用品',
        retailPrice: 12.5,
        costPrice: 6,
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastPath, '/products');
    expect(jsonDecode(adapter.lastBody!), {
      'code': 'SKU-TI',
      'name': '纸巾',
      'unit': '包',
      'category': '日用品',
      'retailPrice': 12.5,
      'costPrice': 6.0,
      'status': 1,
    });
    result.when(
      success: (product) {
        expect(product.id, 11);
        expect(product.name, '纸巾');
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'createProduct rejects success envelope without product payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.createProduct(
        const CreateAdminProductRequest(
          code: 'SKU-TI',
          name: '纸巾',
          unit: '包',
          category: '日用品',
          retailPrice: 12.5,
          costPrice: 6,
        ),
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('createProduct should fail without backend product data'),
        failure: (failure) =>
            expect(failure.message, 'Invalid product response'),
      );
    },
  );

  test(
    'createProduct rejects success envelope with empty product object',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":{}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.createProduct(
        const CreateAdminProductRequest(code: 'SKU-TI', name: '纸巾', unit: '包'),
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('createProduct should fail with an empty product object'),
        failure: (failure) =>
            expect(failure.message, 'Invalid product response'),
      );
    },
  );

  test('updateProduct sends backend product update payload', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":10,"code":"SKU-WA-600","name":"矿泉水 600ml","unit":"瓶","category":"饮料","spec":"600ml","barcode":"6901234567890","retailPrice":4.0,"costPrice":1.5,"imageUrl":"","status":0}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.updateProduct(
      const UpdateAdminProductRequest(
        id: 10,
        code: 'SKU-WA-600',
        name: '矿泉水 600ml',
        unit: '瓶',
        category: '饮料',
        spec: '600ml',
        barcode: '6901234567890',
        retailPrice: 4,
        costPrice: 1.5,
        status: 0,
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/products/10');
    expect(jsonDecode(adapter.lastBody!), {
      'code': 'SKU-WA-600',
      'name': '矿泉水 600ml',
      'unit': '瓶',
      'category': '饮料',
      'spec': '600ml',
      'barcode': '6901234567890',
      'retailPrice': 4.0,
      'costPrice': 1.5,
      'status': 0,
    });
    result.when(
      success: (product) {
        expect(product.id, 10);
        expect(product.name, '矿泉水 600ml');
        expect(product.status, 0);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'updateProduct rejects success envelope with empty product object',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":{}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.updateProduct(
        const UpdateAdminProductRequest(
          id: 10,
          code: 'SKU-WA-600',
          name: '矿泉水 600ml',
          unit: '瓶',
        ),
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('updateProduct should fail with an empty product object'),
        failure: (failure) =>
            expect(failure.message, 'Invalid product response'),
      );
    },
  );

  test('deleteProduct sends backend product delete request', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.deleteProduct(10);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'DELETE');
    expect(adapter.lastPath, '/products/10');
  });

  test('listWarehouses loads backend warehouses endpoint', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":1,"code":"SH","name":"上海仓","status":1,"address":"上海","contactPerson":"王五","contactPhone":"13800000001"}],"total":25,"page":2,"pageSize":20}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listWarehouses(keyword: '上海', page: 2);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastPath, '/warehouses');
    expect(adapter.lastQuery, {'keyword': '上海', 'page': 2, 'pageSize': 20});
    result.when(
      success: (page) {
        expect(page.items.single.id, 1);
        expect(page.items.single.code, 'SH');
        expect(page.items.single.name, '上海仓');
        expect(page.total, 25);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('createWarehouse posts backend warehouse payload', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":2,"code":"BJ","name":"北京仓","status":1,"address":"北京","contactPerson":"赵六","contactPhone":"13800000002"}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.createWarehouse(
      const CreateAdminWarehouseRequest(
        code: 'BJ',
        name: '北京仓',
        address: '北京',
        contactPerson: '赵六',
        contactPhone: '13800000002',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastPath, '/warehouses');
    expect(jsonDecode(adapter.lastBody!), {
      'code': 'BJ',
      'name': '北京仓',
      'status': 1,
      'address': '北京',
      'contactPerson': '赵六',
      'contactPhone': '13800000002',
    });
  });

  test(
    'createWarehouse rejects success envelope without warehouse payload',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":null}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.createWarehouse(
        const CreateAdminWarehouseRequest(code: 'BJ', name: '北京仓'),
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('createWarehouse should fail without backend warehouse data'),
        failure: (failure) =>
            expect(failure.message, 'Invalid warehouse response'),
      );
    },
  );

  test(
    'createWarehouse rejects success envelope with empty warehouse object',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":{}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.createWarehouse(
        const CreateAdminWarehouseRequest(code: 'BJ', name: '北京仓'),
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('createWarehouse should fail with an empty warehouse object'),
        failure: (failure) =>
            expect(failure.message, 'Invalid warehouse response'),
      );
    },
  );

  test('updateWarehouse sends backend warehouse update payload', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"id":1,"code":"SH2","name":"上海二仓","status":0,"address":"上海二仓地址","contactPerson":"王五","contactPhone":"13800000001"}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.updateWarehouse(
      const UpdateAdminWarehouseRequest(
        id: 1,
        code: 'SH2',
        name: '上海二仓',
        status: 0,
        address: '上海二仓地址',
        contactPerson: '王五',
        contactPhone: '13800000001',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/warehouses/1');
    expect(jsonDecode(adapter.lastBody!), {
      'code': 'SH2',
      'name': '上海二仓',
      'status': 0,
      'address': '上海二仓地址',
      'contactPerson': '王五',
      'contactPhone': '13800000001',
    });
  });

  test(
    'updateWarehouse rejects success envelope with empty warehouse object',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":{}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.updateWarehouse(
        const UpdateAdminWarehouseRequest(id: 1, code: 'SH2', name: '上海二仓'),
      );

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('updateWarehouse should fail with an empty warehouse object'),
        failure: (failure) =>
            expect(failure.message, 'Invalid warehouse response'),
      );
    },
  );

  test('deleteWarehouse sends backend warehouse delete request', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.deleteWarehouse(1);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'DELETE');
    expect(adapter.lastPath, '/warehouses/1');
  });

  test('listWarehouseUsers loads warehouse users page and metadata', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":{"list":[{"id":2,"username":"alice","realName":"张三","roleId":2,"roleCode":"user","roleName":"普通用户","status":1}],"total":41,"page":2,"pageSize":20}}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listWarehouseUsers(1, page: 2);

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastPath, '/warehouses/1/users');
    expect(adapter.lastQuery, {'page': 2, 'pageSize': 20});
    result.when(
      success: (page) {
        expect(page.items.single.username, 'alice');
        expect(page.total, 41);
        expect(page.page, 2);
        expect(page.pageSize, 20);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('bindWarehouseUsers posts backend binding payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.bindWarehouseUsers(
      const BindWarehouseUsersRequest(warehouseId: 1, userIds: [2, 3]),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'POST');
    expect(adapter.lastPath, '/warehouses/1/users');
    expect(jsonDecode(adapter.lastBody!), {
      'userIds': [2, 3],
    });
  });

  test('unbindWarehouseUser sends backend unbind request', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.unbindWarehouseUser(
      warehouseId: 1,
      userId: 2,
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'DELETE');
    expect(adapter.lastPath, '/warehouses/1/users/2');
  });

  test('listRoles loads backend roles endpoint', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":[{"id":1,"code":"admin","name":"管理员","status":1,"permissionIds":[1,2]}]}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listRoles();

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastPath, '/roles');
    result.when(
      success: (roles) {
        expect(roles.single.id, 1);
        expect(roles.single.code, 'admin');
        expect(roles.single.permissionIds, [1, 2]);
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test('listRoles rejects role with malformed permission ids', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":[{"id":1,"code":"admin","name":"管理员","status":1,"permissionIds":[1,"bad"]}]}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listRoles();

    expect(result.isFailure, isTrue);
    expect(adapter.lastPath, '/roles');
    result.when(
      success: (_) =>
          fail('listRoles should fail with malformed permission ids'),
      failure: (failure) => expect(failure.message, 'Invalid role response'),
    );
  });

  test('listRoles rejects success envelope with empty role object', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":[{}]}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listRoles();

    expect(result.isFailure, isTrue);
    result.when(
      success: (_) => fail('listRoles should fail with an empty role object'),
      failure: (failure) => expect(failure.message, 'Invalid role response'),
    );
  });

  test('listPermissions loads backend permissions endpoint', () async {
    final adapter = _CapturingAdapter(
      body:
          '{"code":0,"message":"ok","data":[{"id":1,"code":"inventory.read","name":"查看库存","group":"库存"}]}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.listPermissions();

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'GET');
    expect(adapter.lastPath, '/permissions');
    result.when(
      success: (permissions) {
        expect(permissions.single.id, 1);
        expect(permissions.single.code, 'inventory.read');
        expect(permissions.single.name, '查看库存');
      },
      failure: (failure) => fail(failure.message),
    );
  });

  test(
    'listPermissions rejects success envelope with empty permission object',
    () async {
      final adapter = _CapturingAdapter(
        body: '{"code":0,"message":"ok","data":[{}]}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final dataSource = ApiAdminRemoteDataSource(
        ApiClient.test(dio: dio, enableLogging: false),
      );

      final result = await dataSource.listPermissions();

      expect(result.isFailure, isTrue);
      result.when(
        success: (_) =>
            fail('listPermissions should fail with an empty permission object'),
        failure: (failure) =>
            expect(failure.message, 'Invalid permission response'),
      );
    },
  );

  test('updateRolePermissions sends backend permission ids payload', () async {
    final adapter = _CapturingAdapter(
      body: '{"code":0,"message":"ok","data":null}',
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final dataSource = ApiAdminRemoteDataSource(
      ApiClient.test(dio: dio, enableLogging: false),
    );

    final result = await dataSource.updateRolePermissions(
      const UpdateRolePermissionsRequest(roleId: 1, permissionIds: [1, 3]),
    );

    expect(result.isSuccess, isTrue);
    expect(adapter.lastMethod, 'PUT');
    expect(adapter.lastPath, '/roles/1/permissions');
    expect(jsonDecode(adapter.lastBody!), {
      'permissionIds': [1, 3],
    });
  });
}

final class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter({required this.body});

  final String body;
  String? lastPath;
  String? lastMethod;
  String? lastBody;
  Map<String, dynamic>? lastQuery;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastPath = options.path;
    lastMethod = options.method;
    lastQuery = Map<String, dynamic>.from(options.queryParameters);
    if (requestStream != null) {
      final bodyBytes = <int>[];
      await for (final chunk in requestStream) {
        bodyBytes.addAll(chunk);
      }
      lastBody = utf8.decode(bodyBytes);
    }

    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _expectMissingListPayloadFailure<R>({
  required Future<Result<R>> Function(ApiAdminRemoteDataSource dataSource)
  request,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(
    body: '{"code":0,"message":"ok","data":null}',
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiAdminRemoteDataSource(
    ApiClient.test(dio: dio, enableLogging: false),
  );

  final result = await request(dataSource);

  expect(result.isFailure, isTrue);
  result.when(
    success: (_) => fail('list endpoint should fail without backend list data'),
    failure: (failure) => expect(failure.message, expectedMessage),
  );
}

Future<void> _expectMalformedListItemFailure<R>({
  required Future<Result<R>> Function(ApiAdminRemoteDataSource dataSource)
  request,
  required String expectedMessage,
}) async {
  final adapter = _CapturingAdapter(
    body: '{"code":0,"message":"ok","data":{"list":["bad-item"]}}',
  );
  final dio = Dio()..httpClientAdapter = adapter;
  final dataSource = ApiAdminRemoteDataSource(
    ApiClient.test(dio: dio, enableLogging: false),
  );

  final result = await request(dataSource);

  expect(result.isFailure, isTrue);
  result.when(
    success: (_) => fail('list endpoint should fail with malformed list item'),
    failure: (failure) => expect(failure.message, expectedMessage),
  );
}
