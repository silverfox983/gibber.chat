import 'package:flutter_test/flutter_test.dart';
import 'package:xmpp_stone/xmpp_stone.dart' as xmpp;
import 'package:xml/xml.dart' as xml;

void main() {
  test('parsing', () {
    final rawXml = '''<iq from='telegram.hot-chilli.im' type='result' id='disco_info_123'><query xmlns='http://jabber.org/protocol/disco#info'><identity name='Telegram (slidge)' category='conference' type='text'/><identity name='Telegram (slidge)' category='account' type='registered'/><identity name='Telegram (slidge)' category='pubsub' type='pep'/><identity name='Telegram (slidge)' category='gateway' type='telegram'/><feature var='jabber:iq:search'/></query></iq>''';
    
    final document = xml.XmlDocument.parse(rawXml);
    final iqElement = document.rootElement;
    
    final stanza = xmpp.IqStanza(iqElement.getAttribute('id'), xmpp.IqStanzaType.RESULT);
    
    final queryXml = iqElement.findElements('query').first;
    final queryNode = xmpp.XmppElement();
    queryNode.name = 'query';
    
    for (var child in queryXml.children) {
      if (child is xml.XmlElement) {
        final childNode = xmpp.XmppElement();
        childNode.name = child.name.local;
        for (var attr in child.attributes) {
          childNode.addAttribute(xmpp.XmppAttribute(attr.name.local, attr.value));
        }
        queryNode.addChild(childNode);
      }
    }
    
    stanza.addChild(queryNode);

    final infoQueryRes = stanza.getChild('query');
    if (infoQueryRes != null) {
      print("Found query!");
      final identities = infoQueryRes.children.where((e) => e.name == 'identity').cast<xmpp.XmppElement>().toList();
      print("Found \${identities.length} identity elements");
      
      for (var identity in identities) {
        print("Category: \${identity.getAttribute('category')?.value}");
        if (identity.getAttribute('category')?.value == 'gateway') {
          final name = identity.getAttribute('name')?.value;
          final type = identity.getAttribute('type')?.value;
          print("MATCH! Name: \$name, Type: \$type");
        }
      }
    }
  });
}
