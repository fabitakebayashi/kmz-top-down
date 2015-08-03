import haxe.io.Input;  // para poder usar Input, ao invés de haxe.io.Input (linha 15, 16)
import sys.io.File;  // para poder usar Input, ao invés de sys.io.File

class KmzTopDown {
	static function getElementName(xml:Xml) {
		return xml.elementsNamed("name").next().firstChild().nodeValue;
	}

	static function findFolders(xml:Xml){
		var ret = [];
		if(xml.nodeType==Element && xml.nodeName=="Folder")
			ret.push(getElementName(xml)); //"nunca faça isto (sobre next())"
		for (e in xml.elements())
			ret = ret.concat(findFolders(e));
		return ret;
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

	static function processLabels(xml:Xml, kmzTopDownData:Map<Int, {idPleito:Int, idAgrup:Int, idAncora:Int, tipoProj:String, resAHP:String, localProj:String, infraProj:String}>,doc:Xml){
		trace(getElementName(xml));
		for (folder in xml.elementsNamed("Folder")){
			$type(folder);
			processLabels(folder,kmzTopDownData,doc);
		}
		for (pmark in xml.elementsNamed("Placemark")){
			var idPlacemark=getElementName(pmark);
			$type(idPlacemark);
			var data=kmzTopDownData.get(Std.parseInt(idPlacemark));
			if (data==null){
				trace('Falta info para pleito $idPlacemark');
				continue;
			}
			var outFolder = getOrAddFolder(doc, data.resAHP);
			var agrupFolder = getOrAddFolder(outFolder, Std.string(data.idAgrup));
			var pleitoFolder = getOrAddFolder(agrupFolder, idPlacemark);
			pleitoFolder.addChild(pmark);
		}

	}

	static function createIcons(doc:Xml, out:List<haxe.zip.Entry>, iconsData:{codAncora: Dynamic, codProjeto:Dynamic, categoria: Dynamic, source: String}){
		var iconsPath = sys.FileSystem.readDirectory(iconsData.source);
		for (path in iconsPath){
			if (!StringTools.endsWith(path.toLowerCase(), ".png"))
				continue;
			var kmzPath = "icons/" + path;
			var style = Xml.parse('<Style id="$kmzPath"><IconStyle><Icon><href>$kmzPath</href></Icon></IconStyle></Style>');
			doc.insertChild(style,1);
			out.add({
				fileName : kmzPath,
				fileTime : Date.now(),
				data : sys.io.File.getBytes('${iconsData.source}/$path'),
				compressed : false,
				fileSize : 0,
				dataSize :  0,
				crc32 : null
			});
		}
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

		trace("Pookyto");

		var args = Sys.args(); //mto estúpido!
		trace(args);

		if (args.length < 3)
			throw "Usage: KmzTopDown <data.csv> <icons.json> <kml,kmz> ...";
		var csvPath = args[0];

		var csvData:haxe.io.Input = sys.io.File.read(csvPath, false);
		//var csvData:Input = File.read(csvPath, false);
		//trace(csvData.readLine()); - não usar!!! só para não esquecer!!! não descomentar pq o Jonas explode!!

		var reader = new format.csv.Reader(";");
		reader.reset(null, csvData);

		var kmzTopDownData = new Map();
		for (rec in reader){
			var data = {
				idPleito : Std.parseInt(rec[0]),
				idAgrup : Std.parseInt(rec[1]),
				idAncora : Std.parseInt(rec[2]),
				tipoProj : rec[3],
				resAHP : rec[4],
				localProj : rec[5],
				infraProj : rec[6]
			};

			// ignore se não foi possível parsear idPleito em Int
			if (data.idPleito == null) {
				trace('WARNING: Ignorando linha do csv: ${rec.slice(0,3).join(",")}...');
				continue;
			}

			kmzTopDownData.set(data.idPleito, data);

		}

		var kmlPath = args[2];
		var kmlData:haxe.io.Input = sys.io.File.read(kmlPath,true);
		var kml = Xml.parse(kmlData.readAll().toString());

		var doc=kml.elementsNamed("kml").next().elementsNamed("Document").next();

		var kmzPath = ~/\.kml$/.replace(kmlPath, "_topDown.kmz");
		trace(kmzPath);
		var zentries = new List();
		var zoutput = new haxe.io.BytesOutput();
		var zwriter = new haxe.zip.Writer(zoutput);

		trace(findFolders(kml));

		var iconsPath = args[1];
		var iconsJson = sys.io.File.getContent(iconsPath);
		var iconsData:{codAncora: Dynamic, codProjeto:Dynamic, categoria: Dynamic, source: String} = haxe.Json.parse(iconsJson);

		createIcons(doc, zentries, iconsData);

		//kml.addChild(Xml.createComment("Eu sou um comentário feliz-Pookyto!"));
		//sys.io.File.saveContent("temp.kml", kml.toString());


		for (fname in ["Selecionado", "Análise", "Projetos decididos"])
			getOrAddFolder(doc,fname);

		var ancoraFolder=doc.elementsNamed("Folder").next(); //âncora
		var ancoraContents=ancoraFolder.elementsNamed("Folder");

		var tracadoFolder=ancoraContents.next(); //pasta traçado
		var labelsFolder=ancoraContents.next(); //pasta labels

		processLabels(labelsFolder,kmzTopDownData,doc);

		// escreve o doc.kml no kmz de saída
		var docBytes = haxe.io.Bytes.ofString(kml.toString());
		zentries.add({
			fileName : "doc.kml",
			fileTime : Date.now(),
			data : docBytes,
			compressed : false,
			fileSize : 0,
			dataSize :  0,
			crc32 : null
		});

		// escreve o kmz
		zwriter.write(zentries);
		sys.io.File.saveBytes(kmzPath, zoutput.getBytes());
		sys.io.File.saveBytes("temp.kml", docBytes);
	}
}

