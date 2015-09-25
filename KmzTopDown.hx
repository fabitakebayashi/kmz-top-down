import haxe.io.*;  // para poder usar Input e BytesOutput, ao invés de haxe.io.Input/BytesOutput
import haxe.zip.Entry in ZipEntry;  // para poder user ZipEntry ao invés de haxe.zip.Entry
import sys.io.File;  // para poder usar File, ao invés de sys.io.File

typedef TopDownDataRecord = {
	idPleito : Int,
	idAgrup : Int,
	idAncora : Int,
	tipoProj : String,
	resAHP : String,
	localProj : String,
	infraProj : String,
	posAHP : String,
	nomeProj : String,
	invest : String,
	notaDE : String,
	notaBU : String
}

typedef IconData = {
	codAncora : Dynamic,
	codProjeto : Dynamic,
	categoria : Dynamic,
	categoriaIgnorada : Array<String>,
	source : String
}

class KmzTopDown {
	static function getElementName(xml:Xml) {
		if (xml == null)
			throw "";
		return StringTools.trim(xml.elementsNamed("name").next().firstChild().nodeValue);
	}

	static function findElements(name:String, xml:Xml){
		var ret = [];
		if(xml.nodeType==Element && xml.nodeName==name)
			ret.push(xml); //"nunca faça isto (sobre next())"
		for (e in xml.elements())
			ret = ret.concat(findElements(name, e));
		return ret;
	}

	static function findFolderNames(xml:Xml)
		return findElements("Folder", xml).map(getElementName);

	static function pruneFolders(xml:Xml)
	{
		var elements = [ for (e in xml.elements()) e ];
		for (e in elements)
			pruneFolders(e);
		if (xml.nodeType == Element && xml.nodeName == "Folder") {
			var pmarks = [ for (e in xml.elementsNamed("Placemark")) e ];
			var folders = [ for (e in xml.elementsNamed("Folder")) e ];
			if (pmarks.length + folders.length == 0)
				xml.parent.removeChild(xml);
		}
	}

	// prune (global) unused styles from `doc` **in place**
	static function pruneStyles(doc:Xml)
	{
		var del = new Map();

		// all styles
		for (style in doc.elementsNamed("Style"))
			del[style.get("id")] = style;

		// don't delete used styles
		for (use in findElements("styleUrl", doc)) {
			var url = StringTools.trim(use.firstChild().nodeValue);
			if (!StringTools.startsWith(url, "#"))
				continue;
			del.remove(url.substr(1));
		}

		// actually remove the style nodes
		trace('Pruning ${Lambda.count(del)} unused styles');
		for (node in del)
			doc.removeChild(node);
	}

	// return a pluned list of icon zip entries only keeping those used by
	// existing styles
	static function filterIconEntries(entries:List<ZipEntry>, doc:Xml)
	{
		var keep = new Map();
		for (style in doc.elementsNamed("Style")) {
			for (istyle in style.elementsNamed("IconStyle")) {
				var icon = istyle.elementsNamed("Icon").next();
				if (icon == null) continue;
				var href = icon.elementsNamed("href").next();
				if (href == null) continue;
				var path = StringTools.trim(href.firstChild().nodeValue);
				keep[path] = true;
			}
		}

		trace('Pruning ${entries.length - Lambda.count(keep)} icon zip entries');
		return Lambda.filter(entries, function (e) return keep.exists(e.fileName));
	}

	static function getOrAddFolder(xml:Xml, name:String){
		for (folder in xml.elementsNamed("Folder")){
			var fname=getElementName(folder);
			if (fname==name)
				return folder;

		}

		var folder=Xml.createElement("Folder");
		var folderName=Xml.createElement("name");
		var nameValue=Xml.createPCData(name);

		folderName.addChild(nameValue);
		folder.addChild(folderName);
		xml.addChild(folder);

		return folder;

		// alternativa para criar o folder:
		// var folder = Xml.parse('<Folder><name>$name</name></Folder>');
	}

	static function ensureUtf8(s:String)
	{
		return s == null || haxe.Utf8.validate(s) ? s : haxe.Utf8.encode(s);
	}

	static function selectIcon(iconData:IconData, pmarkData:TopDownDataRecord){
		var ca = Reflect.field(iconData.codAncora, Std.string(pmarkData.idAncora));
		var cp = Reflect.field(Reflect.field(iconData.codProjeto, pmarkData.localProj), pmarkData.infraProj);
		var cc = Reflect.field(iconData.categoria, pmarkData.resAHP);
		var icon = '$ca-$cp$cc';
		if (ca == null || cp == null || cc == null) {
			icon = StringTools.replace(icon, "null", "?");
			var debug = [];
			debug.push('âncora "${pmarkData.idAncora}" => ${ca != null ? ca : "?"}');
			debug.push('infra "${pmarkData.infraProj}", extensão "${pmarkData.localProj}" => ${cp != null ? cp : "?"}');
			debug.push('resultado "${pmarkData.resAHP}" => ${cc != null ? cc : "?"}');
			trace('WARNING falta ícone para o pleito ${pmarkData.idPleito}: $icon\n\t${debug.join("\n\t")}');
		}
		return icon;
	}

	static function processLabels(xml:Xml, topDownData:Map<Int, TopDownDataRecord>, iconData:IconData,doc:Xml){
		trace('Em ${getElementName(xml)}');
		for (folder in xml.elementsNamed("Folder")){
			$type(folder);
			processLabels(folder,topDownData,iconData,doc);
		}
		var rm = [];
		for (pmark in xml.elementsNamed("Placemark")){
			var idPlacemark=getElementName(pmark);
			$type(idPlacemark);
			var data=topDownData.get(Std.parseInt(idPlacemark));
			if (data==null){
				trace('WARNING falta info para pleito $idPlacemark');
				continue;
			}
			if (Lambda.has(iconData.categoriaIgnorada, data.resAHP)) {
				trace('WARNING removendo pleito $idPlacemark (resAHP: ${data.resAHP})');
				rm.push(pmark);
				continue;
			}
			var outFolder = getOrAddFolder(doc, data.resAHP);
			var agrupFolder = getOrAddFolder(outFolder, Std.string(data.idAgrup));
			var pleitoFolder = getOrAddFolder(agrupFolder, idPlacemark);
			pleitoFolder.addChild(pmark);

			if (pmark.elementsNamed("description").hasNext())
				pmark.removeChild(pmark.elementsNamed("description").next());
			var desc = Xml.createElement("description");
			var descFields = [
				{ key : "Posição AHP", val : data.posAHP },
				{ key : "Nome do pleito", val : data.nomeProj },
				{ key : "Valor de investimento (milhares de reais)", val : data.invest },
				{ key : "Nota desempenho econômico", val : data.notaDE },
				{ key : "Nota bottom-up", val : data.notaBU }
			];
			desc.addChild(Xml.createCData(descFields.map(function (x) return '<b>${x.key}</b>: ${x.val}').join("<br/>")));
			pmark.addChild(desc);

			if (!pmark.elementsNamed("Point").hasNext())
				continue;
			var icon = selectIcon(iconData, data);
			if (pmark.elementsNamed("styleUrl").hasNext())
				pmark.removeChild(pmark.elementsNamed("styleUrl").next());
			pmark.addChild(Xml.parse('<styleUrl>#icons/$icon.png</styleUrl>').firstChild());
		}
		for (pmark in rm)
			pmark.parent.removeChild(pmark);
	}

	static function createIcons(doc:Xml, out:List<ZipEntry>, iconData:IconData){
		var iconsPath = sys.FileSystem.readDirectory(iconData.source);
		for (path in iconsPath){
			if (!StringTools.endsWith(path.toLowerCase(), ".png"))
				continue;
			var kmzPath = "icons/" + path;
			var style = Xml.parse('<Style id="$kmzPath"><IconStyle><Icon><href>$kmzPath</href></Icon></IconStyle></Style>').firstChild();
			doc.insertChild(style,1);
			out.add({
				fileName : kmzPath,
				fileTime : Date.now(),
				data : File.getBytes('${iconData.source}/$path'),
				compressed : false,
				fileSize : 0,
				dataSize :  0,
				crc32 : null
			});
		}
	}

	static function process(topDownData:Map<Int,TopDownDataRecord>, iconData:IconData, kmlPath:String)
	{
		var kmlData:Input = File.read(kmlPath,true);
		var kml = Xml.parse(kmlData.readAll().toString());
		var doc=kml.elementsNamed("kml").next().elementsNamed("Document").next();

		var kmzPath = ~/\.kml$/.replace(kmlPath, "_topDown.kmz");
		var dbgPath = ~/\.kml$/.replace(kmlPath, "_topDownDebug.xml");

		var zentries = new List();
		var zoutput = new BytesOutput();
		var zwriter = new haxe.zip.Writer(zoutput);

		trace("Folder Kml elements:\n\t" + findFolderNames(kml).join("\n\t"));

		createIcons(doc, zentries, iconData);

		// kml.addChild(Xml.createComment("Eu sou um comentário feliz-Pookyto!"));

		var ancoraFolder=doc.elementsNamed("Folder").next(); //âncora
		var ancoraContents=ancoraFolder.elementsNamed("Folder");

		var labelsFolder=ancoraContents.next(); //pasta labels
		var tracadoFolder=ancoraContents.next(); //pasta traçado

		if (labelsFolder != null)
			processLabels(labelsFolder,topDownData,iconData,doc);

		if (tracadoFolder != null)
			processLabels(tracadoFolder,topDownData,iconData,doc);  // temporário para traçados, funcionando mas pode falhar no futuro

		// finishing touches
		pruneFolders(doc);
		pruneStyles(doc);
		zentries = filterIconEntries(zentries, doc);
		doc.removeChild(doc.elementsNamed("name").next());
		doc.insertChild(Xml.parse('<name>${ensureUtf8(kmzPath)}</name>').firstChild(), 0);

		// escreve o doc.kml no kmz de saída
		var outBytes = Bytes.ofString(haxe.xml.Printer.print(kml, true));
		zentries.add({
			fileName : "doc.kml",
			fileTime : Date.now(),
			data : outBytes,
			compressed : false,
			fileSize : 0,
			dataSize :  0,
			crc32 : null
		});

		// escreve o kmz
		for (e in zentries) {
			if (e.compressed || e.data == null || e.data.length == 0)
				continue;
			if (e.crc32 == null)
				e.crc32 = haxe.crypto.Crc32.make(e.data);
			e.fileSize = e.data.length;
			haxe.zip.Tools.compress(e, -1);
		}
		zwriter.write(zentries);
		File.saveBytes(kmzPath, zoutput.getBytes());
		File.saveBytes(dbgPath, outBytes);
	}

	static function main() {
		// customiza trace() para melhor legibilidade e para que lide automaticamente com !Utf8 no Windows
		haxe.Log.trace = function (msg, ?pos) {
			msg = Std.string(msg);
			// no Windows, remove Utf8 (decodifica para o que o console está usando)
			if (Sys.systemName() == "Windows" && haxe.Utf8.validate(msg))
				msg = haxe.Utf8.decode(msg);
			// já no Linux ou Mac, converte para Utf8 se já não estiver assim
			if (Sys.systemName() != "Windows" && !haxe.Utf8.validate(msg))
				msg = haxe.Utf8.encode(msg);
			// prepara a mensagem
			msg += '   @ ${pos.className}::${pos.methodName} (${pos.fileName}:${pos.lineNumber})\n';
			if (pos.customParams != null)
				msg += pos.customParams.map(function (x) return '\t$x\n');
			// escreve no console (no output de erro)
			Sys.stderr().writeString(msg);
		}

		trace("Welcome, Pookyto!");

		var args = Sys.args(); //mto estúpido!
		trace('Command line arguments: ${args.join(",")}');
		if (args.length < 3) {
			trace("Usage: KmzTopDown <data.csv> <icons.json> <kml,kmz> ...");
			Sys.exit(-1);
		}
		var csvPath = args[0];
		var iconsPath = args[1];
		var kmlPaths = args.slice(2);

		var csvData:haxe.io.Input = sys.io.File.read(csvPath, false); // ou, mais curto, var csvData:Input = File.read(csvPath, false);
		// trace(csvData.readLine()); - não usar!!! só para não esquecer!!! não descomentar pq o Jonas explode!!
		var reader = new format.csv.Reader(";");
		reader.reset(null, csvData);
		var topDownData = new Map();
		for (rec in reader){
			if (rec.length == 1 && rec[0].length > 0)
				throw 'ERROR missing fields or wrong separator';

			var data = {
				idPleito : Std.parseInt(rec[0]),
				idAgrup : Std.parseInt(rec[1]),
				idAncora : Std.parseInt(rec[2]),
				tipoProj : ensureUtf8(rec[3]),
				resAHP : ensureUtf8(rec[4]),
				localProj : ensureUtf8(rec[5]),
				infraProj : ensureUtf8(rec[6]),
				posAHP : ensureUtf8(rec[7]),
				nomeProj : ensureUtf8(rec[8]),
				invest : ensureUtf8(rec[9]),
				notaDE : ensureUtf8(rec[10]),
				notaBU : ensureUtf8(rec[11])
			};

			// ignore se não foi possível parsear idPleito em Int
			if (data.idPleito == null) {
				trace('WARNING ignorando linha do csv: ${rec.slice(0,3).join(",")}...');
				continue;
			}

			topDownData.set(data.idPleito, data);
		}

		var iconJson = File.getContent(iconsPath);
		var iconData:IconData = haxe.Json.parse(iconJson);

		for (path in kmlPaths) {
			trace('PROCESSANDO $path');
			process(topDownData, iconData, path);
		}
	}
}

